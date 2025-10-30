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

#ifdef __cplusplus
}
#endif
