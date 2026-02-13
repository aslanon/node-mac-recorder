#import "sync_timeline.h"
#import "logging.h"

static dispatch_queue_t MRSyncQueue() {
    static dispatch_once_t onceToken;
    static dispatch_queue_t queue = nil;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.node-mac-recorder.sync-timeline", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL g_expectAudio = NO;
static BOOL g_audioReady = YES;
static CMTime g_videoFirstTimestamp = kCMTimeInvalid;
static BOOL g_videoHoldLogged = NO;
static CMTime g_audioFirstTimestamp = kCMTimeInvalid;
static CMTime g_alignmentDelta = kCMTimeInvalid;
static double g_stopLimitSeconds = -1.0;

// Bidirectional barrier: camera side
static BOOL g_expectCamera = NO;
static BOOL g_cameraReady = YES;
static CMTime g_cameraFirstTimestamp = kCMTimeInvalid;
static CMTime g_audioHoldFirstTimestamp = kCMTimeInvalid;
static BOOL g_audioHoldLogged = NO;

void MRSyncConfigure(BOOL expectAudio) {
    dispatch_sync(MRSyncQueue(), ^{
        g_expectAudio = expectAudio;
        g_audioReady = expectAudio ? NO : YES;
        g_videoFirstTimestamp = kCMTimeInvalid;
        g_videoHoldLogged = NO;
        g_audioFirstTimestamp = kCMTimeInvalid;
        g_alignmentDelta = kCMTimeInvalid;
        g_stopLimitSeconds = -1.0;
        // Reset camera barrier state
        g_expectCamera = NO;
        g_cameraReady = YES;
        g_cameraFirstTimestamp = kCMTimeInvalid;
        g_audioHoldFirstTimestamp = kCMTimeInvalid;
        g_audioHoldLogged = NO;
    });
}

BOOL MRSyncShouldHoldVideoFrame(CMTime timestamp) {
    if (!CMTIME_IS_VALID(timestamp)) {
        return NO;
    }

    __block BOOL shouldHold = NO;
    __block BOOL logHold = NO;
    __block BOOL logRelease = NO;

    dispatch_sync(MRSyncQueue(), ^{
        if (!g_expectAudio || g_audioReady) {
            if (!g_expectAudio) {
                g_videoFirstTimestamp = kCMTimeInvalid;
                g_audioFirstTimestamp = kCMTimeInvalid;
                g_alignmentDelta = kCMTimeInvalid;
                g_videoHoldLogged = NO;
                shouldHold = NO;
                return;
            }
            
            if (CMTIME_IS_VALID(g_audioFirstTimestamp) &&
                CMTIME_COMPARE_INLINE(timestamp, <, g_audioFirstTimestamp)) {
                shouldHold = YES;
                return;
            }
            
            g_videoFirstTimestamp = kCMTimeInvalid;
            g_videoHoldLogged = NO;
            shouldHold = NO;
            return;
        }

        if (!CMTIME_IS_VALID(g_videoFirstTimestamp)) {
            g_videoFirstTimestamp = timestamp;
            shouldHold = YES;
            if (!g_videoHoldLogged) {
                g_videoHoldLogged = YES;
                logHold = YES;
            }
            return;
        }

        CMTime elapsed = CMTimeSubtract(timestamp, g_videoFirstTimestamp);
        CMTime maxWait = CMTimeMakeWithSeconds(1.0, 600); // SYNC FIX: Increased from 0.25s to 1.0s for better sync tolerance
        if (CMTIME_COMPARE_INLINE(elapsed, >, maxWait)) {
            g_audioReady = YES;
            g_videoFirstTimestamp = kCMTimeInvalid;
            g_videoHoldLogged = NO;
            shouldHold = NO;
            logRelease = YES;
            return;
        }

        shouldHold = YES;
    });

    if (logHold) {
        MRLog(@"⏸️ Video pipeline waiting for audio to begin (holding frames up to 1.0s)");
    } else if (logRelease) {
        MRLog(@"▶️ Video pipeline resume forced (audio not detected within 1.0s)");
    }

    return shouldHold;
}

void MRSyncMarkAudioSample(CMTime timestamp) {
    if (!CMTIME_IS_VALID(timestamp)) {
        return;
    }

    __block BOOL logRelease = NO;
    __block CMTime delta = kCMTimeInvalid;
    dispatch_sync(MRSyncQueue(), ^{
        if (g_audioReady) {
            return;
        }
        if (!CMTIME_IS_VALID(g_audioFirstTimestamp)) {
            g_audioFirstTimestamp = timestamp;
        }
        if (CMTIME_IS_VALID(g_videoFirstTimestamp)) {
            delta = CMTimeSubtract(timestamp, g_videoFirstTimestamp);
            g_alignmentDelta = delta;
        }
        g_audioReady = YES;
        g_videoFirstTimestamp = kCMTimeInvalid;
        g_videoHoldLogged = NO;
        logRelease = YES;
    });

    if (logRelease) {
        if (CMTIME_IS_VALID(delta)) {
            MRLog(@"🎯 Audio capture detected after %.0f ms - releasing video sync hold",
                  CMTimeGetSeconds(delta) * 1000.0);
        } else {
            MRLog(@"🎯 Audio capture detected - releasing video sync hold");
        }
    }
}

CMTime MRSyncVideoAlignmentOffset(void) {
    __block CMTime offset = kCMTimeInvalid;
    dispatch_sync(MRSyncQueue(), ^{
        offset = g_alignmentDelta;
    });
    return offset;
}

CMTime MRSyncAudioFirstTimestamp(void) {
    __block CMTime ts = kCMTimeInvalid;
    dispatch_sync(MRSyncQueue(), ^{
        ts = g_audioFirstTimestamp;
    });
    return ts;
}

void MRSyncConfigureCamera(BOOL expectCamera) {
    dispatch_sync(MRSyncQueue(), ^{
        g_expectCamera = expectCamera;
        g_cameraReady = expectCamera ? NO : YES;
        g_cameraFirstTimestamp = kCMTimeInvalid;
        g_audioHoldFirstTimestamp = kCMTimeInvalid;
        g_audioHoldLogged = NO;
    });
    if (expectCamera) {
        MRLog(@"🔄 A/V SYNC: Bidirectional barrier enabled - audio will wait for camera");
    }
}

void MRSyncMarkCameraFirstFrame(CMTime timestamp) {
    if (!CMTIME_IS_VALID(timestamp)) {
        return;
    }

    __block BOOL logRelease = NO;
    dispatch_sync(MRSyncQueue(), ^{
        if (g_cameraReady) {
            return;
        }
        if (!CMTIME_IS_VALID(g_cameraFirstTimestamp)) {
            g_cameraFirstTimestamp = timestamp;
        }
        g_cameraReady = YES;
        g_audioHoldFirstTimestamp = kCMTimeInvalid;
        g_audioHoldLogged = NO;
        logRelease = YES;
    });

    if (logRelease) {
        MRLog(@"🎥 A/V SYNC: Camera first frame received - releasing audio hold");
    }
}

BOOL MRSyncShouldHoldAudioSample(CMTime timestamp) {
    if (!CMTIME_IS_VALID(timestamp)) {
        return NO;
    }

    __block BOOL shouldHold = NO;
    __block BOOL logHold = NO;
    __block BOOL logRelease = NO;

    dispatch_sync(MRSyncQueue(), ^{
        if (!g_expectCamera || g_cameraReady) {
            shouldHold = NO;
            return;
        }

        // Camera not yet ready - hold audio samples
        if (!CMTIME_IS_VALID(g_audioHoldFirstTimestamp)) {
            g_audioHoldFirstTimestamp = timestamp;
            shouldHold = YES;
            if (!g_audioHoldLogged) {
                g_audioHoldLogged = YES;
                logHold = YES;
            }
            return;
        }

        // Safety timeout: release after 1.0s even if camera hasn't started
        CMTime elapsed = CMTimeSubtract(timestamp, g_audioHoldFirstTimestamp);
        CMTime maxWait = CMTimeMakeWithSeconds(1.0, 600);
        if (CMTIME_COMPARE_INLINE(elapsed, >, maxWait)) {
            g_cameraReady = YES;
            g_audioHoldFirstTimestamp = kCMTimeInvalid;
            g_audioHoldLogged = NO;
            shouldHold = NO;
            logRelease = YES;
            return;
        }

        shouldHold = YES;
    });

    if (logHold) {
        MRLog(@"⏸️ A/V SYNC: Audio holding samples until camera produces first frame (max 1.0s)");
    } else if (logRelease) {
        MRLog(@"▶️ A/V SYNC: Audio hold released by timeout (camera not detected within 1.0s)");
    }

    return shouldHold;
}

void MRSyncSetStopLimitSeconds(double seconds) {
    dispatch_sync(MRSyncQueue(), ^{
        g_stopLimitSeconds = seconds;
    });
}

double MRSyncGetStopLimitSeconds(void) {
    __block double seconds = -1.0;
    dispatch_sync(MRSyncQueue(), ^{
        seconds = g_stopLimitSeconds;
    });
    return seconds;
}
