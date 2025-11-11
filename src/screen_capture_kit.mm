#import "screen_capture_kit.h"
#import "logging.h"
#import "sync_timeline.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

// Pure ScreenCaptureKit implementation - NO AVFoundation
static SCStream * API_AVAILABLE(macos(12.3)) g_stream = nil;
static id<SCStreamDelegate> API_AVAILABLE(macos(12.3)) g_streamDelegate = nil;
static BOOL g_isRecording = NO;
static BOOL g_isCleaningUp = NO;  // Prevent recursive cleanup
static BOOL g_isScheduling = NO;  // Prevent overlapping start sequences
static NSString *g_outputPath = nil;

// ELECTRON FIX: Track when ScreenCaptureKit has actually started capturing frames
static BOOL g_firstFrameReceived = NO;
static NSInteger g_frameCountSinceStart = 0;

static dispatch_queue_t g_videoQueue = nil;
static dispatch_queue_t g_audioQueue = nil;
static id g_videoStreamOutput = nil;
static id g_audioStreamOutput = nil;

static AVAssetWriter *g_videoWriter = nil;
static AVAssetWriterInput *g_videoInput = nil;
static CFTypeRef g_pixelBufferAdaptorRef = NULL;
static CMTime g_videoStartTime = kCMTimeInvalid;
static BOOL g_videoWriterStarted = NO;

static BOOL g_shouldCaptureAudio = NO;
static NSString *g_audioOutputPath = nil;
static AVAssetWriter *g_audioWriter = nil;
static AVAssetWriterInput *g_systemAudioInput = nil;
static AVAssetWriterInput *g_microphoneAudioInput = nil;
static CMTime g_audioStartTime = kCMTimeInvalid;
static BOOL g_audioWriterStarted = NO;
static BOOL g_captureMicrophoneEnabled = NO;
static BOOL g_captureSystemAudioEnabled = NO;
static BOOL g_mixAudioEnabled = YES;
static float g_mixMicGain = 0.8f;
static float g_mixSystemGain = 0.4f;

static NSInteger g_configuredSampleRate = 48000;
static NSInteger g_configuredChannelCount = 2;
static NSInteger g_targetFPS = 60;

// Frame rate debugging
static NSInteger g_frameCount = 0;
static CFAbsoluteTime g_firstFrameTime = 0;

static dispatch_queue_t ScreenCaptureControlQueue(void);
static void SCKMarkSchedulingComplete(void);
static void SCKFailScheduling(void);
static void SCKPerformRecordingSetup(NSDictionary *config, SCShareableContent *content) API_AVAILABLE(macos(12.3));

static void CleanupWriters(void);

static AVAssetWriterInputPixelBufferAdaptor * _Nullable CurrentPixelBufferAdaptor(void) {
    if (!g_pixelBufferAdaptorRef) {
        return nil;
    }
    return (__bridge AVAssetWriterInputPixelBufferAdaptor *)g_pixelBufferAdaptorRef;
}

static NSString *MRNormalizePath(id value) {
    if (!value || value == (id)kCFNull) {
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }
    if ([value isKindOfClass:[NSURL class]]) {
        return [(NSURL *)value path];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        for (id entry in (NSArray *)value) {
            NSString *candidate = MRNormalizePath(entry);
            if (candidate.length > 0) {
                return candidate;
            }
        }
    }
    return nil;
}

static void FinishWriter(AVAssetWriter *writer, AVAssetWriterInput *input) {
    if (!writer) {
        return;
    }
    
    if (input) {
        [input markAsFinished];
    }
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC));
    dispatch_semaphore_wait(semaphore, timeout);
}

static void CleanupWriters(void) {
    if (g_videoWriter) {
        FinishWriter(g_videoWriter, g_videoInput);
        g_videoWriter = nil;
        g_videoInput = nil;
        if (g_pixelBufferAdaptorRef) {
            CFRelease(g_pixelBufferAdaptorRef);
            g_pixelBufferAdaptorRef = NULL;
        }
        g_videoWriterStarted = NO;
        g_videoStartTime = kCMTimeInvalid;

        // Reset frame counting
        g_frameCount = 0;
        g_firstFrameTime = 0;
    }
    
    if (g_audioWriter) {
        if (g_systemAudioInput) {
            [g_systemAudioInput markAsFinished];
        }
        if (g_microphoneAudioInput) {
            [g_microphoneAudioInput markAsFinished];
        }
        FinishWriter(g_audioWriter, nil);
        g_audioWriter = nil;
        g_systemAudioInput = nil;
        g_microphoneAudioInput = nil;
        g_audioWriterStarted = NO;
        g_audioStartTime = kCMTimeInvalid;
        g_captureMicrophoneEnabled = NO;
        g_captureSystemAudioEnabled = NO;
    }
}

@interface PureScreenCaptureDelegate : NSObject <SCStreamDelegate>
@end

// External helpers for mixing/muxing
extern "C" NSString *currentStandaloneAudioRecordingPath(void);
extern "C" NSString *lastStandaloneAudioRecordingPath(void);
extern "C" BOOL MRMixAudioToSingleTrack(NSString *primaryAudioPath,
                                         NSString *externalMicPath,
                                         BOOL preferInternalTracks);
extern "C" BOOL MRMixAudioToSingleTrackWithGains(NSString *primaryAudioPath,
                                                  NSString *externalMicPath,
                                                  BOOL preferInternalTracks,
                                                  float micGain,
                                                  float systemGain);
extern "C" BOOL MRMuxAudioIntoVideo(NSString *videoPath, NSString *audioPath);

extern "C" NSString *ScreenCaptureKitCurrentAudioPath(void) {
    if (!g_audioOutputPath) {
        return nil;
    }
    if ([g_audioOutputPath isKindOfClass:[NSArray class]]) {
        id first = [(NSArray *)g_audioOutputPath firstObject];
        if ([first isKindOfClass:[NSString class]]) {
            return first;
        }
        return nil;
    }
    return g_audioOutputPath;
}

@implementation PureScreenCaptureDelegate
- (void)stream:(SCStream * API_AVAILABLE(macos(12.3)))stream didStopWithError:(NSError *)error API_AVAILABLE(macos(12.3)) {
    // ELECTRON FIX: Run cleanup on background thread to avoid blocking Electron
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        MRLog(@"🛑 Pure ScreenCapture stream stopped");

        // Prevent recursive calls during cleanup
        if (g_isCleaningUp) {
            MRLog(@"⚠️ Already cleaning up, ignoring delegate callback");
            return;
        }

        @synchronized([ScreenCaptureKitRecorder class]) {
            g_isRecording = NO;
        }

        if (error) {
            NSLog(@"❌ Stream error: %@", error);
        } else {
            MRLog(@"✅ Stream stopped cleanly");
        }

        // Finalize on background thread with synchronization
        @synchronized([ScreenCaptureKitRecorder class]) {
            if (!g_isCleaningUp) {
                [ScreenCaptureKitRecorder finalizeRecording];
            }
        }
    });
}
@end

@interface ScreenCaptureKitRecorder (Private)
+ (BOOL)prepareAudioWriterIfNeededWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
                                     isMicrophone:(BOOL)isMicrophone;
@end

@interface ScreenCaptureVideoOutput : NSObject <SCStreamOutput>
@end

@implementation ScreenCaptureVideoOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
    if (!g_isRecording || type != SCStreamOutputTypeScreen) {
        return;
    }
    
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    
    if (!g_videoWriter || !g_videoInput) {
        return;
    }
    
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    MRSyncMarkAudioSample(presentationTime);
    
    // Wait for audio to arrive before starting screen video to prevent leading frames.
    if (MRSyncShouldHoldVideoFrame(presentationTime)) {
        return;
    }
    
    if (!g_videoWriterStarted) {
        if (![g_videoWriter startWriting]) {
            NSLog(@"❌ ScreenCaptureKit video writer failed to start: %@", g_videoWriter.error);
            return;
        }
        [g_videoWriter startSessionAtSourceTime:kCMTimeZero];
        g_videoStartTime = presentationTime;
        g_videoWriterStarted = YES;
        g_frameCountSinceStart = 0;
        MRLog(@"🎞️ Video writer session started @ %.3f (zero-based timeline)", CMTimeGetSeconds(presentationTime));
    }

    // ELECTRON FIX: Track frame count to ensure ScreenCaptureKit is fully running
    if (!g_firstFrameReceived) {
        g_frameCountSinceStart++;
        if (g_frameCountSinceStart >= 10) {  // Wait for 10 frames (~150ms at 60fps)
            g_firstFrameReceived = YES;
            MRLog(@"✅ ScreenCaptureKit fully initialized after %ld frames", (long)g_frameCountSinceStart);
        }
    }
    
    if (!g_videoInput.readyForMoreMediaData) {
        return;
    }
    
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) {
        return;
    }
    
    AVAssetWriterInputPixelBufferAdaptor *adaptorCandidate = CurrentPixelBufferAdaptor();
    if ([adaptorCandidate isKindOfClass:[NSArray class]]) {
        id first = [(NSArray *)adaptorCandidate firstObject];
        if ([first isKindOfClass:[AVAssetWriterInputPixelBufferAdaptor class]]) {
            adaptorCandidate = first;
            if (g_pixelBufferAdaptorRef) {
                CFRelease(g_pixelBufferAdaptorRef);
            }
            g_pixelBufferAdaptorRef = CFBridgingRetain(adaptorCandidate);
        }
    }
    if (![adaptorCandidate isKindOfClass:[AVAssetWriterInputPixelBufferAdaptor class]]) {
        if (adaptorCandidate) {
            MRLog(@"⚠️ Pixel buffer adaptor invalid (%@) – skipping frame", NSStringFromClass([adaptorCandidate class]));
        }
        NSLog(@"❌ Pixel buffer adaptor is nil – cannot append video frames");
        return;
    }
    
    CMTime relativePresentation = presentationTime;
    if (CMTIME_IS_VALID(g_videoStartTime)) {
        relativePresentation = CMTimeSubtract(presentationTime, g_videoStartTime);
        if (CMTIME_COMPARE_INLINE(relativePresentation, <, kCMTimeZero)) {
            relativePresentation = kCMTimeZero;
        }
    }

    double stopLimit = MRSyncGetStopLimitSeconds();
    if (stopLimit > 0) {
        double frameSeconds = CMTimeGetSeconds(relativePresentation);
        double tolerance = g_targetFPS > 0 ? (1.5 / g_targetFPS) : 0.02;
        if (tolerance < 0.02) {
            tolerance = 0.02;
        }
        if (frameSeconds > stopLimit + tolerance) {
            return;
        }
    }
    
    AVAssetWriterInputPixelBufferAdaptor *adaptor = adaptorCandidate;
    BOOL appended = [adaptor appendPixelBuffer:pixelBuffer withPresentationTime:relativePresentation];
    if (!appended) {
        NSLog(@"⚠️ Failed appending pixel buffer: %@", g_videoWriter.error);
    }

    // Frame rate debugging
    g_frameCount++;
    if (g_firstFrameTime == 0) {
        g_firstFrameTime = CFAbsoluteTimeGetCurrent();
    }
    if (g_frameCount % 60 == 0) {
        CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - g_firstFrameTime;
        double actualFPS = g_frameCount / elapsed;
        MRLog(@"📊 Frame stats: %ld frames in %.1fs = %.1f FPS", (long)g_frameCount, elapsed, actualFPS);
    }
}
@end

@interface ScreenCaptureAudioOutput : NSObject <SCStreamOutput>
@end

@implementation ScreenCaptureAudioOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type API_AVAILABLE(macos(12.3)) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        MRLog(@"🎤 First audio sample callback received from ScreenCaptureKit");
    });

    if (!g_isRecording || !g_shouldCaptureAudio) {
        return;
    }

    BOOL isMicrophoneSample = NO;
    BOOL isSupportedSample = NO;
    if (@available(macOS 15.0, *)) {
        if (type == SCStreamOutputTypeAudio) {
            isSupportedSample = YES;
        } else if (type == SCStreamOutputTypeMicrophone) {
            isSupportedSample = YES;
            isMicrophoneSample = YES;
        }
    } else if (@available(macOS 13.0, *)) {
        if (type == SCStreamOutputTypeAudio) {
            isSupportedSample = YES;
        }
    }

    if (!isSupportedSample) {
        return;
    }

    BOOL routeToMicrophoneTrack = isMicrophoneSample;
    if (!routeToMicrophoneTrack) {
        if (!g_captureSystemAudioEnabled && g_captureMicrophoneEnabled) {
            // Only microphone requested (e.g., macOS < 15), so treat stream as microphone.
            routeToMicrophoneTrack = YES;
        }
    }

    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        MRLog(@"⚠️ %@ audio sample buffer not ready",
              routeToMicrophoneTrack ? @"Microphone" : @"System");
        return;
    }
    
    if (![ScreenCaptureKitRecorder prepareAudioWriterIfNeededWithSampleBuffer:sampleBuffer
                                                                 isMicrophone:routeToMicrophoneTrack]) {
        return;
    }
    
    if (!g_audioWriter) {
        return;
    }

    AVAssetWriterInput *targetInput = routeToMicrophoneTrack ? g_microphoneAudioInput : g_systemAudioInput;
    if (!targetInput) {
        return;
    }
    
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    if (!g_audioWriterStarted) {
        if (![g_audioWriter startWriting]) {
            NSLog(@"❌ Audio writer failed to start: %@", g_audioWriter.error);
            return;
        }
        [g_audioWriter startSessionAtSourceTime:kCMTimeZero];
        g_audioStartTime = presentationTime;
        g_audioWriterStarted = YES;
        MRLog(@"🔊 Audio writer session started @ %.3f (source=%@)",
              CMTimeGetSeconds(presentationTime),
              routeToMicrophoneTrack ? @"microphone" : @"system");
    }
    
    static int systemNotReadyCount = 0;
    static int microphoneNotReadyCount = 0;
    int *notReadyCounter = routeToMicrophoneTrack ? &microphoneNotReadyCount : &systemNotReadyCount;

    if (!targetInput.readyForMoreMediaData) {
        if ((*notReadyCounter)++ % 100 == 0) {
            MRLog(@"⚠️ %@ audio input not ready for data (count: %d)",
                  routeToMicrophoneTrack ? @"Microphone" : @"System",
                  *notReadyCounter);
        }
        return;
    }

    if (CMTIME_IS_INVALID(g_audioStartTime)) {
        g_audioStartTime = presentationTime;
    }
    
    CMSampleBufferRef bufferToAppend = sampleBuffer;
    CMItemCount timingEntryCount = 0;
    OSStatus timingStatus = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 0, NULL, &timingEntryCount);
    CMSampleTimingInfo *timingInfo = NULL;
    
    if (timingStatus == noErr && timingEntryCount > 0) {
        timingInfo = (CMSampleTimingInfo *)malloc(sizeof(CMSampleTimingInfo) * timingEntryCount);
        if (timingInfo) {
            timingStatus = CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, timingEntryCount, timingInfo, &timingEntryCount);
            
            if (timingStatus == noErr) {
                for (CMItemCount i = 0; i < timingEntryCount; ++i) {
                    // Shift ScreenCaptureKit audio to start at t=0 so it aligns with camera/mic tracks
                    if (CMTIME_IS_VALID(timingInfo[i].presentationTimeStamp)) {
                        CMTime adjustedPTS = CMTimeSubtract(timingInfo[i].presentationTimeStamp, g_audioStartTime);
                        if (CMTIME_COMPARE_INLINE(adjustedPTS, <, kCMTimeZero)) {
                            adjustedPTS = kCMTimeZero;
                        }
                        timingInfo[i].presentationTimeStamp = adjustedPTS;
                    } else {
                        timingInfo[i].presentationTimeStamp = kCMTimeZero;
                    }
                    
                    if (CMTIME_IS_VALID(timingInfo[i].decodeTimeStamp)) {
                        CMTime adjustedDTS = CMTimeSubtract(timingInfo[i].decodeTimeStamp, g_audioStartTime);
                        if (CMTIME_COMPARE_INLINE(adjustedDTS, <, kCMTimeZero)) {
                            adjustedDTS = kCMTimeZero;
                        }
                        timingInfo[i].decodeTimeStamp = adjustedDTS;
                    }
                }
                
                CMSampleBufferRef adjustedBuffer = NULL;
                timingStatus = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault,
                                                                     sampleBuffer,
                                                                     timingEntryCount,
                                                                     timingInfo,
                                                                     &adjustedBuffer);
                if (timingStatus == noErr && adjustedBuffer) {
                    bufferToAppend = adjustedBuffer;
                }
            }
            
            free(timingInfo);
            timingInfo = NULL;
        }
    }
    
    double stopLimit = MRSyncGetStopLimitSeconds();
    if (stopLimit > 0) {
        CMTime sampleStart = CMSampleBufferGetPresentationTimeStamp(bufferToAppend);
        double sampleSeconds = CMTimeGetSeconds(sampleStart);
        double sampleDuration = CMTIME_IS_VALID(CMSampleBufferGetDuration(bufferToAppend))
                              ? CMTimeGetSeconds(CMSampleBufferGetDuration(bufferToAppend))
                              : 0.0;
        double tolerance = 0.02;
        if (sampleSeconds > stopLimit + tolerance ||
            (sampleDuration > 0.0 && (sampleSeconds + sampleDuration) > stopLimit + tolerance)) {
            if (bufferToAppend != sampleBuffer) {
                CFRelease(bufferToAppend);
            }
            return;
        }
    }

    BOOL success = [targetInput appendSampleBuffer:bufferToAppend];
    if (!success) {
        NSLog(@"⚠️ Failed appending audio sample buffer: %@", g_audioWriter.error);
    } else {
        static int systemAppendCount = 0;
        static int microphoneAppendCount = 0;
        int *appendCount = routeToMicrophoneTrack ? &microphoneAppendCount : &systemAppendCount;
        if ((*appendCount)++ % 100 == 0) {
            MRLog(@"✅ %@ audio sample appended (count: %d)",
                  routeToMicrophoneTrack ? @"Microphone" : @"System",
                  *appendCount);
        }
    }
    
    if (bufferToAppend != sampleBuffer) {
        CFRelease(bufferToAppend);
    }
}
@end

@implementation ScreenCaptureKitRecorder

+ (BOOL)prepareVideoWriterWithWidth:(NSInteger)width height:(NSInteger)height error:(NSError **)error {
    MRLog(@"🎬 Preparing video writer %ldx%ld", (long)width, (long)height);
    if (!g_outputPath) {
        MRLog(@"❌ Video writer failed: missing output path");
        return NO;
    }
    if (width <= 0 || height <= 0) {
        MRLog(@"❌ Video writer invalid dimensions %ldx%ld", (long)width, (long)height);
        return NO;
    }
    
    NSURL *outputURL = [NSURL fileURLWithPath:g_outputPath];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    
    g_videoWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:error];
    if (!g_videoWriter || (error && *error)) {
        MRLog(@"❌ Failed creating video writer: %@", error && *error ? (*error).localizedDescription : @"unknown");
        return NO;
    }
    
    // QUALITY FIX: ULTRA HIGH quality for screen recording
    // ProMotion displays may run at 10Hz (low power) = 10 FPS capture
    // Solution: Use VERY HIGH bitrate so each frame is perfect quality
    // Use 30x multiplier for ULTRA quality (was 6x - way too low!)
    NSInteger bitrate = (NSInteger)(width * height * 30);
    bitrate = MAX(bitrate, 30 * 1000 * 1000);  // Minimum 30 Mbps for crystal clear screen recording
    bitrate = MIN(bitrate, 120 * 1000 * 1000); // Maximum 120 Mbps for ultra quality

    MRLog(@"🎬 ULTRA QUALITY Screen encoder: %ldx%ld, bitrate=%.2fMbps",
          (long)width, (long)height, bitrate / (1000.0 * 1000.0));

    NSDictionary *compressionProps = @{
        AVVideoAverageBitRateKey: @(bitrate),
        AVVideoMaxKeyFrameIntervalKey: @(MAX(1, g_targetFPS)),
        AVVideoAllowFrameReorderingKey: @YES,
        AVVideoExpectedSourceFrameRateKey: @(MAX(1, g_targetFPS)),
        AVVideoQualityKey: @(0.95),  // 0.0-1.0, higher is better (0.95 = excellent)
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC
    };

    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: compressionProps
    };
    
    g_videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    g_videoInput.expectsMediaDataInRealTime = YES;
    
    AVAssetWriterInputPixelBufferAdaptor *pixelAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:g_videoInput sourcePixelBufferAttributes:@{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    }];

    if (![g_videoWriter canAddInput:g_videoInput]) {
        MRLog(@"❌ Cannot add video input to writer");
        if (error) {
            *error = [NSError errorWithDomain:@"ScreenCaptureKitRecorder" code:-100 userInfo:@{NSLocalizedDescriptionKey: @"Cannot add video input to writer"}];
        }
        return NO;
    }
    
    [g_videoWriter addInput:g_videoInput];
    if (g_pixelBufferAdaptorRef) {
        CFRelease(g_pixelBufferAdaptorRef);
        g_pixelBufferAdaptorRef = NULL;
    }
    if (pixelAdaptor) {
        g_pixelBufferAdaptorRef = CFBridgingRetain(pixelAdaptor);
    }
    g_videoWriterStarted = NO;
    g_videoStartTime = kCMTimeInvalid;
    MRLog(@"✅ Video writer ready %ldx%ld", (long)width, (long)height);

    return YES;
}

+ (BOOL)prepareAudioWriterIfNeededWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
                                     isMicrophone:(BOOL)isMicrophone {
    if (!g_shouldCaptureAudio || !g_audioOutputPath) {
        return g_audioWriter != nil || !g_shouldCaptureAudio;
    }

    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDescription) {
        NSLog(@"⚠️ Missing audio format description");
        return NO;
    }

    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (!asbd) {
        NSLog(@"⚠️ Unsupported audio format description");
        return NO;
    }

    if (!g_audioWriter) {
        g_configuredSampleRate = (NSInteger)asbd->mSampleRate;
        g_configuredChannelCount = asbd->mChannelsPerFrame;

        NSString *originalPath = g_audioOutputPath ?: @"";
        NSURL *audioURL = [NSURL fileURLWithPath:originalPath];
        [[NSFileManager defaultManager] removeItemAtURL:audioURL error:nil];

        NSError *writerError = nil;
        AVFileType requestedFileType = AVFileTypeQuickTimeMovie;

        NSString *audioPath = originalPath;
        if (![audioPath.pathExtension.lowercaseString isEqualToString:@"mov"]) {
            MRLog(@"⚠️ Audio path has wrong extension '%@', changing to .mov", audioPath.pathExtension);
            audioPath = [[audioPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mov"];
            g_audioOutputPath = audioPath;
        }
        audioURL = [NSURL fileURLWithPath:audioPath];
        [[NSFileManager defaultManager] removeItemAtURL:audioURL error:nil];

        @try {
            g_audioWriter = [[AVAssetWriter alloc] initWithURL:audioURL
                                                      fileType:requestedFileType
                                                         error:&writerError];
        } @catch (NSException *exception) {
            NSDictionary *info = @{
                NSLocalizedDescriptionKey: exception.reason ?: @"Failed to initialize audio writer"
            };
            writerError = [NSError errorWithDomain:@"ScreenCaptureKitRecorder" code:-201 userInfo:info];
            g_audioWriter = nil;
        }

        if (!g_audioWriter || writerError) {
            NSLog(@"❌ Failed to create audio writer: %@", writerError);
            return NO;
        }

        // Reset tracking flags whenever we create a new writer
        g_audioWriterStarted = NO;
        g_audioStartTime = kCMTimeInvalid;

        // CRITICAL FIX: Add BOTH system and microphone inputs NOW (before startWriting)
        // if both are enabled. AVAssetWriter cannot add inputs after startWriting() is called.
        NSLog(@"🎙️ Creating audio writer - system=%d, microphone=%d",
              g_captureSystemAudioEnabled, g_captureMicrophoneEnabled);
    }

    AVAssetWriterInput **targetInput = isMicrophone ? &g_microphoneAudioInput : &g_systemAudioInput;
    if (*targetInput) {
        return YES;
    }

    // If writer was just created and BOTH sources are enabled, create BOTH inputs now
    if (g_audioWriter && g_captureSystemAudioEnabled && g_captureMicrophoneEnabled) {
        if (!g_systemAudioInput && !g_microphoneAudioInput) {
            NSLog(@"🎙️ Both audio sources enabled - creating both inputs from first sample");

            NSUInteger channelCount = MAX((NSUInteger)1, (NSUInteger)asbd->mChannelsPerFrame);
            AudioChannelLayout layout = {0};
            size_t layoutSize = 0;
            if (channelCount == 1) {
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
                layoutSize = sizeof(AudioChannelLayout);
            } else if (channelCount == 2) {
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
                layoutSize = sizeof(AudioChannelLayout);
            }

            NSMutableDictionary *audioSettings = [@{
                AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                AVSampleRateKey: @(asbd->mSampleRate),
                AVNumberOfChannelsKey: @(channelCount),
                AVEncoderBitRateKey: @(192000)
            } mutableCopy];

            if (layoutSize > 0) {
                audioSettings[AVChannelLayoutKey] = [NSData dataWithBytes:&layout length:layoutSize];
            }

            // ELECTRON FIX: Create microphone input FIRST (stream 0)
            // Electron plays stream 0 by default, so put the more important audio first
            // TODO: Mix both streams into single track for full Electron compatibility
            AVAssetWriterInput *micInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                                              outputSettings:audioSettings];
            micInput.expectsMediaDataInRealTime = YES;
            if ([g_audioWriter canAddInput:micInput]) {
                [g_audioWriter addInput:micInput];
                g_microphoneAudioInput = micInput;
                NSLog(@"✅ Microphone audio input created (stream 0 - Electron default)");
            } else {
                NSLog(@"❌ Cannot add microphone audio input");
            }

            // Create system audio input (stream 1)
            AVAssetWriterInput *systemInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                                                  outputSettings:audioSettings];
            systemInput.expectsMediaDataInRealTime = YES;
            if ([g_audioWriter canAddInput:systemInput]) {
                [g_audioWriter addInput:systemInput];
                g_systemAudioInput = systemInput;
                NSLog(@"✅ System audio input created (stream 1)");
            } else {
                NSLog(@"❌ Cannot add system audio input");
            }

            return YES;
        }
    }

    NSUInteger channelCount = MAX((NSUInteger)1, (NSUInteger)asbd->mChannelsPerFrame);
    AudioChannelLayout layout = {0};
    size_t layoutSize = 0;
    if (channelCount == 1) {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
        layoutSize = sizeof(AudioChannelLayout);
    } else if (channelCount == 2) {
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
        layoutSize = sizeof(AudioChannelLayout);
    }

    NSMutableDictionary *audioSettings = [@{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(asbd->mSampleRate),
        AVNumberOfChannelsKey: @(channelCount),
        AVEncoderBitRateKey: @(192000)
    } mutableCopy];

    if (layoutSize > 0) {
        audioSettings[AVChannelLayoutKey] = [NSData dataWithBytes:&layout length:layoutSize];
    }

    AVAssetWriterInput *newInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                                      outputSettings:audioSettings];
    newInput.expectsMediaDataInRealTime = YES;

    if (![g_audioWriter canAddInput:newInput]) {
        NSLog(@"❌ Audio writer cannot add %@ input", isMicrophone ? @"microphone" : @"system");
        return NO;
    }
    [g_audioWriter addInput:newInput];

    if (isMicrophone) {
        g_microphoneAudioInput = newInput;
        MRLog(@"🎙️ Microphone audio input created: sampleRate=%.0f, channels=%ld",
              asbd->mSampleRate, (long)channelCount);
    } else {
        g_systemAudioInput = newInput;
        MRLog(@"🔈 System audio input created: sampleRate=%.0f, channels=%ld",
              asbd->mSampleRate, (long)channelCount);
    }

    return YES;
}

+ (BOOL)isScreenCaptureKitAvailable {
    if (@available(macOS 15.0, *)) {
        return [SCShareableContent class] != nil && [SCStream class] != nil && [SCRecordingOutput class] != nil;
    }
    return NO;
}

+ (BOOL)startRecordingWithConfiguration:(NSDictionary *)config delegate:(id)delegate error:(NSError **)error {
    if (!config) {
        return NO;
    }

    NSDictionary *configCopy = [config copy];
    dispatch_queue_t controlQueue = ScreenCaptureControlQueue();
    __block BOOL accepted = NO;

    dispatch_sync(controlQueue, ^{
        if (g_isRecording || g_isCleaningUp || g_isScheduling) {
            MRLog(@"⚠️ ScreenCaptureKit busy (recording:%d cleaning:%d scheduling:%d)", g_isRecording, g_isCleaningUp, g_isScheduling);
            accepted = NO;
            return;
        }
        g_isCleaningUp = NO;
        g_isScheduling = YES;
        accepted = YES;
    });

    if (!accepted) {
        return NO;
    }

    // CRITICAL FIX: Use dispatch_get_global_queue instead of main_queue
    // because Node.js standalone doesn't run macOS main event loop (only Electron does)
    NSLog(@"🚀 Requesting shareable content...");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *contentError) {
            if (contentError || !content) {
                NSLog(@"❌ Content error: %@", contentError);
                SCKFailScheduling();
                return;
            }
            NSLog(@"✅ Got shareable content, starting recording setup...");
            dispatch_async(controlQueue, ^{
                SCKPerformRecordingSetup(configCopy, content);
            });
        }];
    });

    return YES;
}

+ (void)stopRecording {
    if (!g_isRecording || !g_stream || g_isCleaningUp) {
        NSLog(@"⚠️ Cannot stop: recording=%d stream=%@ cleaning=%d", g_isRecording, g_stream, g_isCleaningUp);
        SCKMarkSchedulingComplete();
        return;
    }

    MRLog(@"🛑 Stopping pure ScreenCaptureKit recording");

    // CRITICAL FIX: Set cleanup flag IMMEDIATELY to prevent race conditions
    // This prevents startRecording from being called while stop is in progress
    @synchronized([ScreenCaptureKitRecorder class]) {
        g_isCleaningUp = YES;
    }

    // Store stream reference to prevent it from being deallocated
    SCStream *streamToStop = g_stream;

    // ELECTRON FIX: Stop FULLY ASYNCHRONOUSLY - NO blocking, NO semaphores
    [streamToStop stopCaptureWithCompletionHandler:^(NSError *stopError) {
        @autoreleasepool {
            if (stopError) {
                NSLog(@"❌ Stop error: %@", stopError);
            } else {
                MRLog(@"✅ Pure stream stopped");
            }

            // Reset recording state to allow new recordings
            @synchronized([ScreenCaptureKitRecorder class]) {
                g_isRecording = NO;
                g_isCleaningUp = NO; // CRITICAL: Reset cleanup flag when done
            }

            // Cleanup after stop completes
            CleanupWriters();
            [ScreenCaptureKitRecorder cleanupVideoWriter];

            // Post-process: mix (if enabled) then mux audio into video file
            if (g_shouldCaptureAudio && g_audioOutputPath) {
                NSString *primaryAudioPath = ScreenCaptureKitCurrentAudioPath();
                if ([primaryAudioPath isKindOfClass:[NSArray class]]) {
                    id first = [(NSArray *)primaryAudioPath firstObject];
                    if ([first isKindOfClass:[NSString class]]) {
                        primaryAudioPath = (NSString *)first;
                    } else {
                        primaryAudioPath = nil;
                    }
                }
                if (primaryAudioPath && [primaryAudioPath length] > 0) {
                    BOOL preferInternal = NO;
                    if (@available(macOS 15.0, *)) {
                        preferInternal = (g_captureSystemAudioEnabled && g_captureMicrophoneEnabled);
                    }
                    NSString *externalMicPath = nil;
                    if (currentStandaloneAudioRecordingPath) {
                        externalMicPath = currentStandaloneAudioRecordingPath();
                    }
                    if (!externalMicPath || [externalMicPath length] == 0) {
                        if (lastStandaloneAudioRecordingPath) {
                            externalMicPath = lastStandaloneAudioRecordingPath();
                        }
                    }
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                        NSString *audioForMux = primaryAudioPath;
                        if (g_mixAudioEnabled) {
                            BOOL mixed = NO;
                            // Try gain-aware mix first
                            mixed = MRMixAudioToSingleTrackWithGains(primaryAudioPath, externalMicPath, preferInternal, g_mixMicGain, g_mixSystemGain);
                            if (!mixed) {
                                mixed = MRMixAudioToSingleTrack(primaryAudioPath, externalMicPath, preferInternal);
                            }
                            if (mixed) {
                                MRLog(@"🎧 Post-mix completed: %@", primaryAudioPath);
                            } else {
                                MRLog(@"ℹ️ Post-mix skipped or failed; proceeding to mux");
                            }
                        }
                        if (g_outputPath && [g_outputPath length] > 0) {
                            BOOL muxed = MRMuxAudioIntoVideo(g_outputPath, audioForMux);
                            if (muxed) {
                                MRLog(@"🔗 Muxed audio into video: %@", g_outputPath);
                            } else {
                                MRLog(@"⚠️ Failed to mux audio into video %@", g_outputPath);
                            }
                        }
                    });
                }
            }

            SCKMarkSchedulingComplete();
        }
    }];
}

+ (BOOL)isRecording {
    return g_isRecording;
}

+ (BOOL)isFullyInitialized {
    return g_firstFrameReceived;
}

+ (NSTimeInterval)getVideoStartTimestamp {
    if (!CMTIME_IS_VALID(g_videoStartTime)) {
        return 0;
    }
    // Return as milliseconds since epoch - approximate using current time
    // and relative offset from video start
    NSDate *now = [NSDate date];
    NSTimeInterval currentTimestamp = [now timeIntervalSince1970] * 1000;

    // Calculate time elapsed since video start
    CMTime currentCMTime = CMClockGetTime(CMClockGetHostTimeClock());
    CMTime elapsedCMTime = CMTimeSubtract(currentCMTime, g_videoStartTime);
    NSTimeInterval elapsedSeconds = CMTimeGetSeconds(elapsedCMTime);

    // Video start timestamp = current timestamp - elapsed time
    NSTimeInterval videoStartTimestamp = currentTimestamp - (elapsedSeconds * 1000);
    return videoStartTimestamp;
}

+ (BOOL)isCleaningUp {
    return g_isCleaningUp;
}

@end

// Export C function for checking cleanup state
BOOL isScreenCaptureKitCleaningUp() API_AVAILABLE(macos(12.3)) {
    return [ScreenCaptureKitRecorder isCleaningUp];
}

@implementation ScreenCaptureKitRecorder (Methods)

+ (BOOL)setupVideoWriter {
    // No setup needed - SCRecordingOutput handles everything
    return YES;
}

+ (void)finalizeRecording {
    @synchronized([ScreenCaptureKitRecorder class]) {
        MRLog(@"🎬 Finalizing pure ScreenCaptureKit recording");
        
        // Set cleanup flag now that we're actually cleaning up
        g_isCleaningUp = YES;
        g_isRecording = NO;
        
        [ScreenCaptureKitRecorder cleanupVideoWriter];
    }
}

+ (void)finalizeVideoWriter {
    // Alias for finalizeRecording to maintain compatibility
    [ScreenCaptureKitRecorder finalizeRecording];
}

+ (void)cleanupVideoWriter {
    @synchronized([ScreenCaptureKitRecorder class]) {
        MRLog(@"🧹 Starting ScreenCaptureKit cleanup");
        
        // Clean up in proper order to prevent crashes
        if (g_stream) {
            g_stream = nil;
            MRLog(@"✅ Stream reference cleared");
        }
        
        if (g_streamDelegate) {
            g_streamDelegate = nil;
            MRLog(@"✅ Stream delegate reference cleared");
        }
        
        g_videoStreamOutput = nil;
        g_audioStreamOutput = nil;
        g_videoQueue = nil;
        g_audioQueue = nil;
        if (g_pixelBufferAdaptorRef) {
            CFRelease(g_pixelBufferAdaptorRef);
            g_pixelBufferAdaptorRef = NULL;
        }
        g_audioOutputPath = nil;
        g_shouldCaptureAudio = NO;
        g_captureMicrophoneEnabled = NO;
        g_captureSystemAudioEnabled = NO;

        g_isRecording = NO;
        g_isCleaningUp = NO;  // Reset cleanup flag
        g_outputPath = nil;

        // ELECTRON FIX: Reset frame tracking
        g_firstFrameReceived = NO;
        g_frameCountSinceStart = 0;
        
        MRLog(@"🧹 Pure ScreenCaptureKit cleanup complete");
    }
}

@end
static dispatch_queue_t ScreenCaptureControlQueue(void) {
    static dispatch_queue_t controlQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controlQueue = dispatch_queue_create("com.macrecorder.screencapture.control", DISPATCH_QUEUE_SERIAL);
    });
    return controlQueue;
}

static void SCKMarkSchedulingComplete(void) {
    g_isScheduling = NO;
}

static void SCKFailScheduling(void) {
    g_isScheduling = NO;
    g_isRecording = NO;
}

static void SCKPerformRecordingSetup(NSDictionary *config, SCShareableContent *content) API_AVAILABLE(macos(12.3)) {
    @autoreleasepool {
        if (!config || !content) {
            SCKFailScheduling();
            return;
        }

        // CRITICAL FIX: Reset frame tracking at START of new recording
        g_firstFrameReceived = NO;
        g_frameCountSinceStart = 0;
        NSLog(@"🔄 Frame tracking reset for new recording");

        NSString *outputPath = config[@"outputPath"];
        if (!outputPath || [outputPath length] == 0) {
            NSLog(@"❌ Invalid output path provided");
            SCKFailScheduling();
            return;
        }
        g_outputPath = outputPath;

        NSNumber *displayId = config[@"displayId"];
        NSNumber *windowId = config[@"windowId"];
        NSDictionary *captureRect = config[@"captureRect"];
        NSNumber *captureCursor = config[@"captureCursor"];
        NSNumber *includeMicrophone = config[@"includeMicrophone"];
        NSNumber *includeSystemAudio = config[@"includeSystemAudio"];
        NSString *microphoneDeviceId = config[@"microphoneDeviceId"];
        NSString *audioOutputPath = MRNormalizePath(config[@"audioOutputPath"]);
        NSNumber *sessionTimestampNumber = config[@"sessionTimestamp"];
        NSNumber *frameRateNumber = config[@"frameRate"];
        NSNumber *mixAudioNumber = config[@"mixAudio"];
        g_mixAudioEnabled = mixAudioNumber ? [mixAudioNumber boolValue] : YES;
        NSNumber *mixMicGainNumber = config[@"mixMicGain"];
        NSNumber *mixSystemGainNumber = config[@"mixSystemGain"];
        if (mixMicGainNumber && [mixMicGainNumber respondsToSelector:@selector(floatValue)]) {
            g_mixMicGain = [mixMicGainNumber floatValue];
            if (g_mixMicGain < 0.f) g_mixMicGain = 0.f;
            if (g_mixMicGain > 2.f) g_mixMicGain = 2.f;
        }
        if (mixSystemGainNumber && [mixSystemGainNumber respondsToSelector:@selector(floatValue)]) {
            g_mixSystemGain = [mixSystemGainNumber floatValue];
            if (g_mixSystemGain < 0.f) g_mixSystemGain = 0.f;
            if (g_mixSystemGain > 2.f) g_mixSystemGain = 2.f;
        }
        NSNumber *captureCamera = config[@"captureCamera"];

        if (frameRateNumber && [frameRateNumber respondsToSelector:@selector(intValue)]) {
            NSInteger fps = [frameRateNumber intValue];
            if (fps < 1) fps = 1;
            if (fps > 120) fps = 120;
            g_targetFPS = fps;
        } else {
            g_targetFPS = 60;
        }

        // CRITICAL ELECTRON FIX: Lower FPS to 30 when recording with camera
        // This prevents resource conflicts and crashes when running both simultaneously
        BOOL isCameraEnabled = captureCamera && [captureCamera boolValue];
        if (isCameraEnabled && g_targetFPS > 30) {
            MRLog(@"📹 Camera recording detected - lowering ScreenCaptureKit FPS from %ld to 30 for stability", (long)g_targetFPS);
            g_targetFPS = 30;
        }

        MRLog(@"🎬 Starting PURE ScreenCaptureKit recording (NO AVFoundation)");
        MRLog(@"🔧 Config: cursor=%@ mic=%@ system=%@ display=%@ window=%@ crop=%@",
              captureCursor, includeMicrophone, includeSystemAudio, displayId, windowId, captureRect);
        MRLog(@"🔍 AUDIO DEBUG: includeMicrophone type=%@ value=%d", [includeMicrophone class], [includeMicrophone boolValue]);
        MRLog(@"🔍 AUDIO DEBUG: includeSystemAudio type=%@ value=%d", [includeSystemAudio class], [includeSystemAudio boolValue]);
        MRLog(@"🎚️ Post-mix enabled: %@ (mic=%.2f, sys=%.2f)", g_mixAudioEnabled ? @"YES" : @"NO", g_mixMicGain, g_mixSystemGain);

        MRLog(@"✅ Got %lu displays, %lu windows for pure recording",
              content.displays.count, content.windows.count);
        MRLog(@"🔍 ScreenCaptureKit available displays:");
        for (SCDisplay *display in content.displays) {
            MRLog(@"   Display ID=%u, Size=%dx%d, Frame=(%.0f,%.0f,%.0fx%.0f)",
                  display.displayID, (int)display.width, (int)display.height,
                  display.frame.origin.x, display.frame.origin.y,
                  display.frame.size.width, display.frame.size.height);
        }

        SCContentFilter *filter = nil;
        NSInteger recordingWidth = 0;
        NSInteger recordingHeight = 0;
        SCDisplay *targetDisplay = nil;

        if (windowId && [windowId integerValue] != 0) {
            SCRunningApplication *targetApp = nil;
            SCWindow *targetWindow = nil;

            for (SCWindow *window in content.windows) {
                if (window.windowID == [windowId unsignedIntValue]) {
                    targetWindow = window;
                    targetApp = window.owningApplication;
                    break;
                }
            }

            if (targetWindow && targetApp) {
                MRLog(@"🪟 Recording window: %@ (%ux%u)",
                      targetWindow.title, (unsigned)targetWindow.frame.size.width, (unsigned)targetWindow.frame.size.height);
                filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];
                recordingWidth = (NSInteger)targetWindow.frame.size.width;
                recordingHeight = (NSInteger)targetWindow.frame.size.height;
            } else {
                NSLog(@"❌ Window ID %@ not found", windowId);
                SCKFailScheduling();
                return;
            }
        } else {
            if (displayId) {
                for (SCDisplay *display in content.displays) {
                    if (display.displayID == [displayId unsignedIntValue]) {
                        targetDisplay = display;
                        break;
                    }
                }

                if (!targetDisplay && content.displays.count > 0) {
                    NSUInteger count = content.displays.count;
                    NSUInteger idx0 = (NSUInteger)[displayId unsignedIntValue];
                    if (idx0 < count) {
                        targetDisplay = content.displays[idx0];
                    } else if ([displayId unsignedIntegerValue] > 0) {
                        NSUInteger idx1 = [displayId unsignedIntegerValue] - 1;
                        if (idx1 < count) {
                            targetDisplay = content.displays[idx1];
                        }
                    }
                }
            }

            if (!targetDisplay && content.displays.count > 0) {
                targetDisplay = content.displays.firstObject;
            }

            if (targetDisplay) {
                MRLog(@"🖥️ Recording display %u (%dx%d)",
                      targetDisplay.displayID, (int)targetDisplay.width, (int)targetDisplay.height);
                filter = [[SCContentFilter alloc] initWithDisplay:targetDisplay excludingWindows:@[]];
                recordingWidth = targetDisplay.width;
                recordingHeight = targetDisplay.height;
            } else {
                NSLog(@"❌ No display available");
                SCKFailScheduling();
                return;
            }
        }

        if (captureRect && captureRect[@"width"] && captureRect[@"height"]) {
            CGFloat cropWidth = [captureRect[@"width"] doubleValue];
            CGFloat cropHeight = [captureRect[@"height"] doubleValue];
            if (cropWidth > 0 && cropHeight > 0) {
                MRLog(@"🔲 Crop area specified: %.0fx%.0f at (%.0f,%.0f)",
                      cropWidth, cropHeight,
                      [captureRect[@"x"] doubleValue], [captureRect[@"y"] doubleValue]);
                recordingWidth = (NSInteger)cropWidth;
                recordingHeight = (NSInteger)cropHeight;
            }
        }

        SCStreamConfiguration *streamConfig = [[SCStreamConfiguration alloc] init];
        streamConfig.width = recordingWidth;
        streamConfig.height = recordingHeight;
        streamConfig.minimumFrameInterval = CMTimeMake(1, (int)MAX(1, g_targetFPS));
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA;
        streamConfig.scalesToFit = NO;
        if (@available(macOS 13.0, *)) {
            streamConfig.queueDepth = 8;
        }

        BOOL shouldCaptureMic = includeMicrophone ? [includeMicrophone boolValue] : NO;
        BOOL shouldCaptureSystemAudio = includeSystemAudio ? [includeSystemAudio boolValue] : NO;
        g_shouldCaptureAudio = shouldCaptureSystemAudio || shouldCaptureMic;
        g_captureMicrophoneEnabled = shouldCaptureMic;
        g_captureSystemAudioEnabled = shouldCaptureSystemAudio;

        if (audioOutputPath && ![audioOutputPath isKindOfClass:[NSString class]]) {
            MRLog(@"⚠️ audioOutputPath type mismatch: %@, converting...", NSStringFromClass([audioOutputPath class]));
            g_audioOutputPath = nil;
        } else {
            g_audioOutputPath = audioOutputPath;
        }

        if (g_shouldCaptureAudio && (!g_audioOutputPath || [g_audioOutputPath length] == 0)) {
            NSLog(@"⚠️ Audio capture requested but no audio output path supplied – audio will be disabled");
            g_shouldCaptureAudio = NO;
            g_captureMicrophoneEnabled = NO;
            g_captureSystemAudioEnabled = NO;
        }

        if (@available(macos 13.0, *)) {
            streamConfig.capturesAudio = g_shouldCaptureAudio;
            streamConfig.sampleRate = g_configuredSampleRate ?: 48000;
            streamConfig.channelCount = g_configuredChannelCount ?: 2;
            streamConfig.excludesCurrentProcessAudio = !shouldCaptureSystemAudio;
            NSLog(@"🎤 Audio config (macOS 13+): capturesAudio=%d, excludeProcess=%d (mic=%d sys=%d)",
                  g_shouldCaptureAudio, streamConfig.excludesCurrentProcessAudio,
                  shouldCaptureMic, shouldCaptureSystemAudio);
        }

        if (@available(macos 15.0, *)) {
            streamConfig.captureMicrophone = shouldCaptureMic;
            NSString *micIdToUse = microphoneDeviceId;
            if (micIdToUse && micIdToUse.length > 0) {
                // Validate UniqueID; if invalid, fall back to default to avoid silencing mic
                AVCaptureDevice *dev = [AVCaptureDevice deviceWithUniqueID:micIdToUse];
                if (!dev) {
                    NSLog(@"⚠️ Invalid microphone deviceID '%@' – falling back to default", micIdToUse);
                    micIdToUse = nil;
                }
            }
            if (micIdToUse && micIdToUse.length > 0) {
                streamConfig.microphoneCaptureDeviceID = micIdToUse;
            }
            NSLog(@"🎤 Microphone (macOS 15+): enabled=%d, deviceID=%@",
                  shouldCaptureMic, micIdToUse ?: @"default");
        }

        if (captureRect && captureRect[@"x"] && captureRect[@"y"] && captureRect[@"width"] && captureRect[@"height"] && targetDisplay) {
            CGFloat globalX = [captureRect[@"x"] doubleValue];
            CGFloat globalY = [captureRect[@"y"] doubleValue];
            CGFloat cropWidth = [captureRect[@"width"] doubleValue];
            CGFloat cropHeight = [captureRect[@"height"] doubleValue];
            CGRect displayBounds = targetDisplay.frame;
            CGFloat displayRelativeX = globalX - displayBounds.origin.x;
            CGFloat displayRelativeY = globalY - displayBounds.origin.y;

            if (displayRelativeX >= 0 && displayRelativeY >= 0 &&
                displayRelativeX + cropWidth <= displayBounds.size.width &&
                displayRelativeY + cropHeight <= displayBounds.size.height) {
                CGRect sourceRect = CGRectMake(displayRelativeX, displayRelativeY, cropWidth, cropHeight);
                streamConfig.sourceRect = sourceRect;
                MRLog(@"✂️ Crop sourceRect applied: (%.0f,%.0f) %.0fx%.0f (display-relative)",
                      displayRelativeX, displayRelativeY, cropWidth, cropHeight);
            } else {
                NSLog(@"❌ Crop coordinates out of display bounds - skipping crop");
                MRLog(@"   Relative: (%.0f,%.0f) size:(%.0fx%.0f) vs display:(%.0fx%.0f)",
                      displayRelativeX, displayRelativeY, cropWidth, cropHeight,
                      displayBounds.size.width, displayBounds.size.height);
            }
        }

        BOOL shouldShowCursor = captureCursor ? [captureCursor boolValue] : YES;
        streamConfig.showsCursor = shouldShowCursor;
        MRLog(@"🎥 Pure ScreenCapture config: %ldx%ld @ %ldfps, cursor=%d",
              recordingWidth, recordingHeight, (long)g_targetFPS, shouldShowCursor);

        NSError *writerError = nil;
        if (![ScreenCaptureKitRecorder prepareVideoWriterWithWidth:recordingWidth height:recordingHeight error:&writerError]) {
            NSLog(@"❌ Failed to prepare video writer: %@", writerError);
            SCKFailScheduling();
            CleanupWriters();
            return;
        }

        g_videoQueue = dispatch_queue_create("screen_capture_video_queue", DISPATCH_QUEUE_SERIAL);
        g_audioQueue = dispatch_queue_create("screen_capture_audio_queue", DISPATCH_QUEUE_SERIAL);
        g_videoStreamOutput = [[ScreenCaptureVideoOutput alloc] init];
        if (g_shouldCaptureAudio) {
            g_audioStreamOutput = [[ScreenCaptureAudioOutput alloc] init];
        } else {
            g_audioStreamOutput = nil;
        }

        g_streamDelegate = [[PureScreenCaptureDelegate alloc] init];
        g_stream = [[SCStream alloc] initWithFilter:filter configuration:streamConfig delegate:g_streamDelegate];
        if (!g_stream) {
            NSLog(@"❌ Failed to create pure stream");
            CleanupWriters();
            SCKFailScheduling();
            return;
        }

        NSError *outputError = nil;
        BOOL videoOutputAdded = [g_stream addStreamOutput:g_videoStreamOutput type:SCStreamOutputTypeScreen sampleHandlerQueue:g_videoQueue error:&outputError];
        if (!videoOutputAdded || outputError) {
            NSLog(@"❌ Failed to add video output: %@", outputError);
            CleanupWriters();
            @synchronized([ScreenCaptureKitRecorder class]) {
                g_stream = nil;
            }
            SCKFailScheduling();
            return;
        }

        if (g_shouldCaptureAudio) {
            if (@available(macOS 13.0, *)) {
                NSError *audioError = nil;
                BOOL anyAudioAdded = NO;
                if (@available(macOS 15.0, *)) {
                    // On macOS 15+, microphone has its own output type
                    if (g_captureMicrophoneEnabled) {
                        NSLog(@"➕ Adding microphone output stream...");
                        audioError = nil;
                        BOOL micAdded = [g_stream addStreamOutput:g_audioStreamOutput
                                                             type:SCStreamOutputTypeMicrophone
                                               sampleHandlerQueue:g_audioQueue
                                                            error:&audioError];
                        if (!micAdded || audioError) {
                            NSLog(@"❌ Failed to add microphone output: %@", audioError);
                            CleanupWriters();
                            @synchronized([ScreenCaptureKitRecorder class]) { g_stream = nil; }
                            SCKFailScheduling();
                            return;
                        }
                        anyAudioAdded = YES;
                        NSLog(@"✅ Microphone output added successfully");
                    }
                    if (g_captureSystemAudioEnabled) {
                        NSLog(@"➕ Adding system audio output stream...");
                        audioError = nil;
                        BOOL sysAdded = [g_stream addStreamOutput:g_audioStreamOutput
                                                            type:SCStreamOutputTypeAudio
                                              sampleHandlerQueue:g_audioQueue
                                                           error:&audioError];
                        if (!sysAdded || audioError) {
                            NSLog(@"❌ Failed to add system audio output: %@", audioError);
                            CleanupWriters();
                            @synchronized([ScreenCaptureKitRecorder class]) { g_stream = nil; }
                            SCKFailScheduling();
                            return;
                        }
                        anyAudioAdded = YES;
                        NSLog(@"✅ System audio output added successfully");
                    }
                } else {
                    // macOS 13/14: only SCStreamOutputTypeAudio exists
                    NSLog(@"➕ Adding audio output stream (macOS 13/14)...");
                    audioError = nil;
                    BOOL audAdded = [g_stream addStreamOutput:g_audioStreamOutput
                                                        type:SCStreamOutputTypeAudio
                                          sampleHandlerQueue:g_audioQueue
                                                       error:&audioError];
                    if (!audAdded || audioError) {
                        NSLog(@"❌ Failed to add audio output: %@", audioError);
                        CleanupWriters();
                        @synchronized([ScreenCaptureKitRecorder class]) { g_stream = nil; }
                        SCKFailScheduling();
                        return;
                    }
                    anyAudioAdded = YES;
                    NSLog(@"✅ Audio output added successfully");
                }

                if (!anyAudioAdded) {
                    NSLog(@"❌ No audio outputs added (unexpected configuration)");
                    CleanupWriters();
                    @synchronized([ScreenCaptureKitRecorder class]) { g_stream = nil; }
                    SCKFailScheduling();
                    return;
                }
            } else {
                NSLog(@"⚠️ Audio capture requested but requires macOS 13.0+");
                g_shouldCaptureAudio = NO;
                g_captureMicrophoneEnabled = NO;
                g_captureSystemAudioEnabled = NO;
            }
        }

        MRLog(@"✅ Stream outputs configured (audio=%d)", g_shouldCaptureAudio);
        if (sessionTimestampNumber) {
            MRLog(@"🕒 Session timestamp: %@", sessionTimestampNumber);
        }

        NSLog(@"🚀 CALLING startCaptureWithCompletionHandler (async)...");
        [g_stream startCaptureWithCompletionHandler:^(NSError *startError) {
            dispatch_async(ScreenCaptureControlQueue(), ^{
                if (startError) {
                    NSLog(@"❌ Failed to start pure capture: %@", startError);
                    NSLog(@"❌ Error domain: %@, code: %ld", startError.domain, (long)startError.code);
                    NSLog(@"❌ Error userInfo: %@", startError.userInfo);
                    CleanupWriters();
                    @synchronized([ScreenCaptureKitRecorder class]) {
                        g_isRecording = NO;
                        g_stream = nil;
                    }
                    SCKFailScheduling();
                } else {
                    NSLog(@"🎉 PURE ScreenCaptureKit recording started successfully!");
                    NSLog(@"🎤 Audio capture enabled: %d (mic=%d, system=%d)", g_shouldCaptureAudio, g_captureMicrophoneEnabled, g_captureSystemAudioEnabled);
                    @synchronized([ScreenCaptureKitRecorder class]) {
                        g_isRecording = YES;
                    }
                    SCKMarkSchedulingComplete();
                }
            });
        }];
    }
}
