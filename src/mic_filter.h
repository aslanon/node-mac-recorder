#ifndef MIC_FILTER_H
#define MIC_FILTER_H

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Microphone filter chain applied while the mic track is written
 * (Noise Gate -> Expander -> 3-Band EQ -> Compressor -> Limiter).
 *
 * Configure with the JSON produced by the desktop app
 * (utils/micFilters.mjs micFiltersForRecorder). nil / empty disables it.
 * Every call also resets the filter state, so call it before each recording.
 */
void MRMicFilterConfigureJSON(NSString *json);

/** YES when a configured chain would change the signal. */
BOOL MRMicFilterIsActive(void);

/**
 * Returns a new (+1 retained) sample buffer with the filtered audio and the
 * same format and timing, or NULL when filtering is off or the format is not
 * linear PCM. Callers keep using the original buffer when NULL comes back.
 * Must be called from a single queue (the mic capture queue).
 */
CMSampleBufferRef MRMicFilterCopyProcessedBuffer(CMSampleBufferRef sampleBuffer);

#ifdef __cplusplus
}

/** Releases a buffer from MRMicFilterCopyProcessedBuffer when the scope ends. */
struct MRMicFilterScopedBuffer {
    CMSampleBufferRef buffer = NULL;
    explicit MRMicFilterScopedBuffer(CMSampleBufferRef b) : buffer(b) {}
    ~MRMicFilterScopedBuffer() { if (buffer) CFRelease(buffer); }
    MRMicFilterScopedBuffer(const MRMicFilterScopedBuffer &) = delete;
    MRMicFilterScopedBuffer &operator=(const MRMicFilterScopedBuffer &) = delete;
};
#endif

#endif // MIC_FILTER_H
