#pragma once
#import <AVFoundation/AVFoundation.h>

// Call only after detaching and draining sample callbacks. A writer which has
// not received its first frame cannot be marked/finished: AVFoundation raises
// NSInternalInconsistencyException, which a JavaScript catch cannot intercept.
static BOOL MRFinishAssetWriterSafely(AVAssetWriter *writer,
                                    NSTimeInterval timeoutSeconds,
                                    double stopLimitSeconds = -1.0) {
    if (!writer) return YES;
    dispatch_semaphore_t finished = nil;
    @try {
        AVAssetWriterStatus status = writer.status;
        if (status == AVAssetWriterStatusCompleted) return YES;
        if (status == AVAssetWriterStatusUnknown) {
            [writer cancelWriting];
            return NO;
        }
        if (status != AVAssetWriterStatusWriting) return NO;
        if (stopLimitSeconds > 0 && isfinite(stopLimitSeconds)) {
            [writer endSessionAtSourceTime:CMTimeMakeWithSeconds(stopLimitSeconds, 600)];
        }
        // Respect each recorder's bounded wait. A global 60-second floor blocks
        // the native stop path synchronously and makes the app appear frozen.
        // Timing out is safe because the writer is deliberately not cancelled.
        NSTimeInterval waitSeconds =
            isfinite(timeoutSeconds) && timeoutSeconds > 0 ? timeoutSeconds : 5.0;
        finished = dispatch_semaphore_create(0);
        // finishWriting marks all inputs as finished. The completion captures
        // only its semaphore, never mutable globals from a subsequent session.
        [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
        long timedOut = dispatch_semaphore_wait(finished,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitSeconds * NSEC_PER_SEC)));
        if (timedOut) {
            // NEVER cancel here. cancelWriting deletes the output file, so a
            // finalization that is merely slow would destroy the user's
            // recording — the editor then opens with no video. Waiting stops,
            // the writer keeps finalizing in the background and still produces
            // the file; only the "completed" confirmation is lost.
            NSLog(@"[Recorder] Writer still finalizing after %.3fs; leaving it to finish", waitSeconds);
            return NO;
        }
        return writer.status == AVAssetWriterStatusCompleted;
    } @catch (NSException *exception) {
        NSLog(@"[Recorder] Writer finalization failed safely: %@", exception.reason);
        @try {
            if (writer.status == AVAssetWriterStatusUnknown) {
                // No first frame arrived, so there is no output file to lose.
                [writer cancelWriting];
            } else if (writer.status == AVAssetWriterStatusWriting) {
                // Frames were written: cancelling would delete them. Trigger
                // finalization best effort instead and do not wait on it.
                [writer finishWritingWithCompletionHandler:^{}];
            }
        } @catch (NSException *cancelError) {
            NSLog(@"[Recorder] Writer cancellation failed: %@", cancelError.reason);
        }
        return NO;
    } @finally {
#if !__has_feature(objc_arc)
        // The copied completion block owns a separate reference, including
        // when it runs after a timeout. Balance this call's create reference.
        if (finished) dispatch_release(finished);
#endif
    }
}
