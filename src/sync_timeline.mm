#import "sync_timeline.h"
#import "logging.h"
#include <vector>

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
static BOOL g_isPaused = NO;
static CFAbsoluteTime g_pauseStartedAt = 0;
static double g_totalPausedSeconds = 0;

// Bidirectional barrier: camera side
static BOOL g_expectCamera = NO;
static BOOL g_cameraReady = YES;
static CMTime g_cameraFirstTimestamp = kCMTimeInvalid;
static CMTime g_audioHoldFirstTimestamp = kCMTimeInvalid;
static BOOL g_audioHoldLogged = NO;

// Primary-source start barrier (USB iPhone screen capture, etc.).
static BOOL g_expectPrimary = NO;
static BOOL g_primaryReady = YES;
static CMTime g_primaryStartTimestamp = kCMTimeInvalid;
static CMTime g_primaryHoldFirstTimestamp = kCMTimeInvalid;
static BOOL g_primaryHoldLogged = NO;
struct MRPrimaryPauseRange { CMTime start; CMTime end; };
static std::vector<MRPrimaryPauseRange> g_primaryPauses;

void MRSyncConfigure(BOOL expectAudio) {
    dispatch_sync(MRSyncQueue(), ^{
        g_expectAudio = expectAudio;
        g_audioReady = expectAudio ? NO : YES;
        g_videoFirstTimestamp = kCMTimeInvalid;
        g_videoHoldLogged = NO;
        g_audioFirstTimestamp = kCMTimeInvalid;
        g_alignmentDelta = kCMTimeInvalid;
        g_stopLimitSeconds = -1.0;
        g_isPaused = NO;
        g_pauseStartedAt = 0;
        g_totalPausedSeconds = 0;
        // Reset camera barrier state
        g_expectCamera = NO;
        g_cameraReady = YES;
        g_cameraFirstTimestamp = kCMTimeInvalid;
        g_audioHoldFirstTimestamp = kCMTimeInvalid;
        g_audioHoldLogged = NO;
        g_expectPrimary = NO;
        g_primaryReady = YES;
        g_primaryStartTimestamp = kCMTimeInvalid;
        g_primaryHoldFirstTimestamp = kCMTimeInvalid;
        g_primaryHoldLogged = NO;
        g_primaryPauses.clear();
    });
}

void MRSyncPause(void) {
    dispatch_sync(MRSyncQueue(), ^{
        if (g_isPaused) return;
        g_isPaused = YES;
        g_pauseStartedAt = CFAbsoluteTimeGetCurrent();
    });
    MRLog(@"⏸️ Recording timeline paused");
}

void MRSyncResume(void) {
    __block BOOL resumed = NO;
    dispatch_sync(MRSyncQueue(), ^{
        if (!g_isPaused) return;
        if (g_pauseStartedAt > 0) {
            g_totalPausedSeconds += MAX(0, CFAbsoluteTimeGetCurrent() - g_pauseStartedAt);
        }
        g_pauseStartedAt = 0;
        g_isPaused = NO;
        resumed = YES;
    });
    if (resumed) MRLog(@"▶️ Recording timeline resumed");
}

BOOL MRSyncIsPaused(void) {
    __block BOOL paused = NO;
    dispatch_sync(MRSyncQueue(), ^{ paused = g_isPaused; });
    return paused;
}

double MRSyncGetPausedDurationSeconds(void) {
    __block double duration = 0;
    dispatch_sync(MRSyncQueue(), ^{
        duration = g_totalPausedSeconds;
        if (g_expectPrimary && g_isPaused && !g_primaryPauses.empty()) {
            duration += MAX(0, CMTimeGetSeconds(CMTimeSubtract(
                CMClockGetTime(CMClockGetHostTimeClock()), g_primaryPauses.back().start)));
        } else if (g_isPaused && g_pauseStartedAt > 0) {
            duration += MAX(0, CFAbsoluteTimeGetCurrent() - g_pauseStartedAt);
        }
    });
    return duration;
}

CMTime MRSyncAdjustForPauses(CMTime relativeTimestamp) {
    if (!CMTIME_IS_VALID(relativeTimestamp)) return relativeTimestamp;
    double seconds = CMTimeGetSeconds(relativeTimestamp) - MRSyncGetPausedDurationSeconds();
    if (!isfinite(seconds) || seconds <= 0) return kCMTimeZero;
    int32_t timescale = relativeTimestamp.timescale > 0 ? relativeTimestamp.timescale : 600;
    return CMTimeMakeWithSeconds(seconds, timescale);
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

void MRSyncConfigurePrimaryStart(BOOL expectPrimary) {
    dispatch_sync(MRSyncQueue(), ^{
        g_expectPrimary = expectPrimary;
        g_primaryReady = expectPrimary ? NO : YES;
        g_primaryStartTimestamp = kCMTimeInvalid;
        g_primaryHoldFirstTimestamp = kCMTimeInvalid;
        g_primaryHoldLogged = NO;
        g_primaryPauses.clear();
    });
    if (expectPrimary) {
        MRLog(@"🔄 A/V SYNC: Primary-source start barrier enabled");
    }
}

BOOL MRSyncUsesPrimaryTimeline(void) {
    __block BOOL enabled = NO;
    dispatch_sync(MRSyncQueue(), ^{ enabled = g_expectPrimary; });
    return enabled;
}

CMTime MRSyncPrimaryStartTimestamp(void) {
    __block CMTime timestamp = kCMTimeInvalid;
    dispatch_sync(MRSyncQueue(), ^{ timestamp = g_primaryStartTimestamp; });
    return timestamp;
}

CMTime MRSyncHostTimestamp(CMTime timestamp, CMClockRef captureClock) {
    if (!CMTIME_IS_NUMERIC(timestamp) || !captureClock) return kCMTimeInvalid;
    return CMSyncConvertTime(timestamp, captureClock, CMClockGetHostTimeClock());
}

CMTime MRSyncPrimaryMediaTime(CMTime hostTimestamp) {
    if (!CMTIME_IS_NUMERIC(hostTimestamp)) return kCMTimeInvalid;
    __block CMTime result = kCMTimeInvalid;
    dispatch_sync(MRSyncQueue(), ^{
        if (!g_expectPrimary || !CMTIME_IS_NUMERIC(g_primaryStartTimestamp) ||
            CMTimeCompare(hostTimestamp, g_primaryStartTimestamp) < 0) return;
        CMTime paused = kCMTimeZero;
        for (const auto &range : g_primaryPauses) {
            if (CMTimeCompare(hostTimestamp, range.start) < 0) break;
            if (!CMTIME_IS_NUMERIC(range.end) || CMTimeCompare(hostTimestamp, range.end) < 0) return;
            paused = CMTimeAdd(paused, CMTimeSubtract(range.end, range.start));
        }
        result = CMTimeSubtract(CMTimeSubtract(hostTimestamp, g_primaryStartTimestamp), paused);
    });
    return result;
}

void MRSyncPauseAtHostTime(CMTime timestamp) {
    if (!CMTIME_IS_NUMERIC(timestamp)) return;
    dispatch_sync(MRSyncQueue(), ^{
        if (!g_expectPrimary || g_isPaused) return;
        g_primaryPauses.push_back({timestamp, kCMTimeInvalid});
        g_isPaused = YES;
    });
}

void MRSyncResumeAtHostTime(CMTime timestamp) {
    if (!CMTIME_IS_NUMERIC(timestamp)) return;
    dispatch_sync(MRSyncQueue(), ^{
        if (!g_expectPrimary || !g_isPaused || g_primaryPauses.empty()) return;
        auto &range = g_primaryPauses.back();
        range.end = CMTimeMaximum(timestamp, range.start);
        g_totalPausedSeconds += CMTimeGetSeconds(CMTimeSubtract(range.end, range.start));
        g_isPaused = NO;
    });
}

void MRSyncMarkPrimaryStarted(CMTime timestamp) {
    if (!CMTIME_IS_VALID(timestamp)) return;

    __block BOOL logRelease = NO;
    dispatch_sync(MRSyncQueue(), ^{
        if (g_primaryReady) return;
        g_primaryStartTimestamp = timestamp;
        g_primaryReady = YES;
        g_primaryHoldFirstTimestamp = kCMTimeInvalid;
        g_primaryHoldLogged = NO;
        logRelease = YES;
    });
    if (logRelease) {
        MRLog(@"🎯 A/V SYNC: Primary source started - releasing camera and microphone");
    }
}

BOOL MRSyncShouldHoldForPrimary(CMTime timestamp) {
    if (!CMTIME_IS_VALID(timestamp)) return NO;

    __block BOOL shouldHold = NO;
    __block BOOL logHold = NO;
    __block BOOL logRelease = NO;
    dispatch_sync(MRSyncQueue(), ^{
        if (!g_expectPrimary || g_primaryReady) {
            if (CMTIME_IS_VALID(g_primaryStartTimestamp) &&
                CMTIME_COMPARE_INLINE(timestamp, <, g_primaryStartTimestamp)) {
                shouldHold = YES;
            }
            return;
        }

        if (!CMTIME_IS_VALID(g_primaryHoldFirstTimestamp)) {
            g_primaryHoldFirstTimestamp = timestamp;
            shouldHold = YES;
            if (!g_primaryHoldLogged) {
                g_primaryHoldLogged = YES;
                logHold = YES;
            }
            return;
        }

        // Fail open if a future primary source forgets to signal start.
        CMTime elapsed = CMTimeSubtract(timestamp, g_primaryHoldFirstTimestamp);
        if (CMTIME_COMPARE_INLINE(elapsed, >, CMTimeMakeWithSeconds(12.0, 600))) {
            g_primaryReady = YES;
            g_primaryHoldFirstTimestamp = kCMTimeInvalid;
            g_primaryHoldLogged = NO;
            shouldHold = NO;
            logRelease = YES;
            return;
        }
        shouldHold = YES;
    });

    if (logHold) {
        MRLog(@"⏸️ A/V SYNC: Camera/microphone waiting for primary source");
    } else if (logRelease) {
        MRLog(@"▶️ A/V SYNC: Primary-source hold released by safety timeout");
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
