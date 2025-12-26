#ifndef AUDIO_PROCESSOR_H
#define AUDIO_PROCESSOR_H

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Real-time audio processor for filtering keyboard/mouse clicks and background noise.
 *
 * Algorithm:
 * - Detects transient sounds (clicks) by analyzing amplitude envelope
 * - Applies noise gate with smooth attack/release
 * - Preserves voice while attenuating short, high-amplitude spikes
 */

/**
 * Process audio buffer to reduce keyboard/mouse clicks and background noise.
 *
 * @param sampleBuffer Input audio buffer (read-only)
 * @param outputBuffer Pointer to receive processed buffer (caller must CFRelease)
 * @param sensitivity Noise gate sensitivity (0.0 - 1.0, default 0.5)
 *                    Lower = more aggressive filtering
 *                    Higher = preserves more sound but may miss some clicks
 * @return YES if processing succeeded, NO otherwise
 */
BOOL processAudioBufferForNoiseReduction(CMSampleBufferRef sampleBuffer,
                                          CMSampleBufferRef *outputBuffer,
                                          Float32 sensitivity);

/**
 * Reset processor state (call when starting new recording)
 */
void resetAudioProcessorState(void);

#ifdef __cplusplus
}
#endif

#endif // AUDIO_PROCESSOR_H
