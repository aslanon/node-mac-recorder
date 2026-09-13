#pragma once

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

#ifdef __cplusplus
extern "C" {
#endif

// Configure synchronization expectations for the current recording session.
// When expectAudio is YES, camera frames will pause until audio samples arrive
// (or a safety timeout elapses) to keep tracks aligned.
void MRSyncConfigure(BOOL expectAudio);

// Called for every video sample. Returns YES if the caller should skip the
// frame until audio starts, ensuring video does not lead the audio track.
BOOL MRSyncShouldHoldVideoFrame(CMTime timestamp);

// Called whenever an audio sample is observed. This releases any camera hold
// so both tracks share the same starting point.
void MRSyncMarkAudioSample(CMTime timestamp);

// Returns the offset between audio and video start timestamps when available.
CMTime MRSyncVideoAlignmentOffset(void);

// Returns the first audio timestamp observed for the current session.
CMTime MRSyncAudioFirstTimestamp(void);

// Bidirectional camera-audio barrier: ensures both start writing from the
// same wall-clock moment for perfect lip sync.
void MRSyncConfigureCamera(BOOL expectCamera);
void MRSyncMarkCameraFirstFrame(CMTime timestamp);
BOOL MRSyncShouldHoldAudioSample(CMTime timestamp);

// Some primary sources (for example a USB iPhone muxed device) need a short
// asynchronous warm-up before their first frame is committed. Camera and
// microphone writers can use this barrier to discard their warm-up samples and
// begin at the same host-clock instant as that primary source.
void MRSyncConfigurePrimaryStart(BOOL expectPrimary);
void MRSyncMarkPrimaryStarted(CMTime timestamp);
BOOL MRSyncShouldHoldForPrimary(CMTime timestamp);

// iPhone-only timeline. Convert each capture session's PTS to the host clock
// before comparing sources; preserve late arrivals instead of rebasing each
// file to its own first sample. Invalid media time means discard the sample.
BOOL MRSyncUsesPrimaryTimeline(void);
CMTime MRSyncPrimaryStartTimestamp(void);
CMTime MRSyncHostTimestamp(CMTime timestamp, CMClockRef captureClock);
CMTime MRSyncPrimaryMediaTime(CMTime hostTimestamp);
void MRSyncPauseAtHostTime(CMTime timestamp);
void MRSyncResumeAtHostTime(CMTime timestamp);

// Optional hard stop limit (seconds) shared across capture components.
void MRSyncSetStopLimitSeconds(double seconds);
double MRSyncGetStopLimitSeconds(void);

// Pause/resume the shared media timeline without closing any writers. Samples
// received while paused are discarded; resumed samples are shifted backwards
// by the accumulated pause duration so every track remains gap-free.
void MRSyncPause(void);
void MRSyncResume(void);
BOOL MRSyncIsPaused(void);
CMTime MRSyncAdjustForPauses(CMTime relativeTimestamp);
double MRSyncGetPausedDurationSeconds(void);

#ifdef __cplusplus
}
#endif
