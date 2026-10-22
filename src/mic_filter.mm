#import "mic_filter.h"
#import "mic_filter_dsp.h"
#import "logging.h"
#import <AudioToolbox/AudioToolbox.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

// One chain for the single mic track of the active recording. Configure runs
// on the JS thread, processing on the mic capture queue; the lock keeps the
// chain consistent between them.
static os_unfair_lock g_micFilterLock = OS_UNFAIR_LOCK_INIT;
static micfilter::Chain g_micFilterChain;
static micfilter::Config g_micFilterConfig;
static bool g_micFilterConfigured = false;   // chain matches config + rate
static double g_micFilterSampleRate = 0;
static UInt32 g_micFilterChannels = 0;

static double MRMicNumber(NSDictionary *dict, NSString *key, double fallback) {
    id value = dict[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        double number = [value doubleValue];
        if (std::isfinite(number)) return number;
    }
    return fallback;
}

static bool MRMicEnabled(NSDictionary *dict) {
    id value = dict[@"enabled"];
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

static NSDictionary *MRMicSection(NSDictionary *root, NSString *key) {
    id value = root[key];
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

void MRMicFilterConfigureJSON(NSString *json) {
    micfilter::Config config;
    if (json.length > 0) {
        NSError *error = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0
                                                      error:&error];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            NSDictionary *root = parsed;
            config.enabled = MRMicEnabled(root);

            NSDictionary *gate = MRMicSection(root, @"noiseGate");
            config.gate.enabled = MRMicEnabled(gate);
            config.gate.closeThresholdDb = MRMicNumber(gate, @"closeThresholdDb", config.gate.closeThresholdDb);
            config.gate.openThresholdDb = MRMicNumber(gate, @"openThresholdDb", config.gate.openThresholdDb);
            config.gate.attackMs = MRMicNumber(gate, @"attackMs", config.gate.attackMs);
            config.gate.holdMs = MRMicNumber(gate, @"holdMs", config.gate.holdMs);
            config.gate.releaseMs = MRMicNumber(gate, @"releaseMs", config.gate.releaseMs);

            NSDictionary *expander = MRMicSection(root, @"expander");
            config.expander.enabled = MRMicEnabled(expander);
            config.expander.thresholdDb = MRMicNumber(expander, @"thresholdDb", config.expander.thresholdDb);
            config.expander.ratio = MRMicNumber(expander, @"ratio", config.expander.ratio);
            config.expander.attackMs = MRMicNumber(expander, @"attackMs", config.expander.attackMs);
            config.expander.releaseMs = MRMicNumber(expander, @"releaseMs", config.expander.releaseMs);

            NSDictionary *eq = MRMicSection(root, @"equalizer");
            config.eq.enabled = MRMicEnabled(eq);
            config.eq.lowCutHz = MRMicNumber(eq, @"lowCutHz", config.eq.lowCutHz);
            config.eq.lowFreqHz = MRMicNumber(eq, @"lowFreqHz", config.eq.lowFreqHz);
            config.eq.lowGainDb = MRMicNumber(eq, @"lowGainDb", config.eq.lowGainDb);
            config.eq.midFreqHz = MRMicNumber(eq, @"midFreqHz", config.eq.midFreqHz);
            config.eq.midGainDb = MRMicNumber(eq, @"midGainDb", config.eq.midGainDb);
            config.eq.highFreqHz = MRMicNumber(eq, @"highFreqHz", config.eq.highFreqHz);
            config.eq.highGainDb = MRMicNumber(eq, @"highGainDb", config.eq.highGainDb);

            NSDictionary *compressor = MRMicSection(root, @"compressor");
            config.compressor.enabled = MRMicEnabled(compressor);
            config.compressor.thresholdDb = MRMicNumber(compressor, @"thresholdDb", config.compressor.thresholdDb);
            config.compressor.ratio = MRMicNumber(compressor, @"ratio", config.compressor.ratio);
            config.compressor.attackMs = MRMicNumber(compressor, @"attackMs", config.compressor.attackMs);
            config.compressor.releaseMs = MRMicNumber(compressor, @"releaseMs", config.compressor.releaseMs);
            config.compressor.makeupDb = MRMicNumber(compressor, @"makeupDb", config.compressor.makeupDb);

            NSDictionary *limiter = MRMicSection(root, @"limiter");
            config.limiter.enabled = MRMicEnabled(limiter);
            config.limiter.thresholdDb = MRMicNumber(limiter, @"thresholdDb", config.limiter.thresholdDb);
            config.limiter.releaseMs = MRMicNumber(limiter, @"releaseMs", config.limiter.releaseMs);
        } else {
            MRLog(@"⚠️ Mic filters: invalid configuration ignored (%@)", error.localizedDescription ?: @"not an object");
        }
    }

    os_unfair_lock_lock(&g_micFilterLock);
    g_micFilterConfig = config;
    g_micFilterConfigured = false;
    g_micFilterSampleRate = 0;
    g_micFilterChannels = 0;
    g_micFilterChain.configure(config, 48000.0);
    bool active = g_micFilterChain.active();
    os_unfair_lock_unlock(&g_micFilterLock);

    MRLog(@"🎚️ Mic filters %@ (gate=%d expander=%d eq=%d compressor=%d limiter=%d)",
          active ? @"ON" : @"OFF",
          config.gate.enabled, config.expander.enabled, config.eq.enabled,
          config.compressor.enabled, config.limiter.enabled);
}

BOOL MRMicFilterIsActive(void) {
    os_unfair_lock_lock(&g_micFilterLock);
    bool active = g_micFilterChain.active();
    os_unfair_lock_unlock(&g_micFilterLock);
    return active ? YES : NO;
}

namespace {

enum class SampleKind { Unsupported, Float32, Float64, Int16, Int32 };

SampleKind sampleKindFor(const AudioStreamBasicDescription *asbd) {
    if (!asbd || asbd->mFormatID != kAudioFormatLinearPCM) return SampleKind::Unsupported;
    if (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) return SampleKind::Unsupported;
    const bool isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isPacked = (asbd->mFormatFlags & kAudioFormatFlagIsPacked) != 0 || asbd->mBitsPerChannel % 8 == 0;
    if (!isPacked) return SampleKind::Unsupported;
    if (isFloat && asbd->mBitsPerChannel == 32) return SampleKind::Float32;
    if (isFloat && asbd->mBitsPerChannel == 64) return SampleKind::Float64;
    if (isFloat) return SampleKind::Unsupported;
    // Fixed-point (8.24) and unsigned integer formats are not used by mic capture.
    if (asbd->mFormatFlags & kAudioFormatFlagIsNonMixable) return SampleKind::Unsupported;
    if (!(asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger)) return SampleKind::Unsupported;
    if (asbd->mBitsPerChannel == 16) return SampleKind::Int16;
    if (asbd->mBitsPerChannel == 32) return SampleKind::Int32;
    return SampleKind::Unsupported;
}

size_t bytesFor(SampleKind kind) {
    switch (kind) {
        case SampleKind::Float32: return 4;
        case SampleKind::Float64: return 8;
        case SampleKind::Int16: return 2;
        case SampleKind::Int32: return 4;
        default: return 0;
    }
}

inline float readSample(const void *data, size_t index, SampleKind kind) {
    switch (kind) {
        case SampleKind::Float32: return ((const float *)data)[index];
        case SampleKind::Float64: return (float)((const double *)data)[index];
        case SampleKind::Int16: return (float)((const SInt16 *)data)[index] / 32768.0f;
        case SampleKind::Int32: return (float)((double)((const SInt32 *)data)[index] / 2147483648.0);
        default: return 0.0f;
    }
}

inline void writeSample(void *data, size_t index, SampleKind kind, float value) {
    if (value > 1.0f) value = 1.0f;
    if (value < -1.0f) value = -1.0f;
    switch (kind) {
        case SampleKind::Float32: ((float *)data)[index] = value; break;
        case SampleKind::Float64: ((double *)data)[index] = value; break;
        case SampleKind::Int16: ((SInt16 *)data)[index] = (SInt16)lrintf(value * 32767.0f); break;
        case SampleKind::Int32: ((SInt32 *)data)[index] = (SInt32)llrint((double)value * 2147483647.0); break;
        default: break;
    }
}

void freeBufferList(AudioBufferList *list, bool ownsData) {
    if (!list) return;
    if (ownsData) {
        for (UInt32 i = 0; i < list->mNumberBuffers; ++i) free(list->mBuffers[i].mData);
    }
    free(list);
}

} // namespace

CMSampleBufferRef MRMicFilterCopyProcessedBuffer(CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) return NULL;

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!format) return NULL;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    const SampleKind kind = sampleKindFor(asbd);
    if (kind == SampleKind::Unsupported) return NULL;
    const UInt32 channels = asbd->mChannelsPerFrame;
    const CMItemCount frames = CMSampleBufferGetNumSamples(sampleBuffer);
    if (channels == 0 || channels > (UInt32)micfilter::kMaxChannels || frames <= 0) return NULL;

    os_unfair_lock_lock(&g_micFilterLock);
    if (!g_micFilterChain.active() && g_micFilterConfigured) {
        os_unfair_lock_unlock(&g_micFilterLock);
        return NULL;
    }
    // (Re)build the chain for this device's rate/channel count. A device switch
    // mid-recording resets envelopes; that only affects a few milliseconds.
    if (!g_micFilterConfigured || g_micFilterSampleRate != asbd->mSampleRate || g_micFilterChannels != channels) {
        g_micFilterChain.configure(g_micFilterConfig, asbd->mSampleRate);
        g_micFilterSampleRate = asbd->mSampleRate;
        g_micFilterChannels = channels;
        g_micFilterConfigured = true;
    }
    if (!g_micFilterChain.active()) {
        os_unfair_lock_unlock(&g_micFilterLock);
        return NULL;
    }
    os_unfair_lock_unlock(&g_micFilterLock);

    size_t listSize = 0;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, &listSize, NULL, 0, NULL, NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, NULL);
    if (status != noErr || listSize == 0) return NULL;

    AudioBufferList *source = (AudioBufferList *)malloc(listSize);
    if (!source) return NULL;
    CMBlockBufferRef sourceBlock = NULL;
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, NULL, source, listSize, NULL, NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &sourceBlock);
    if (status != noErr) {
        free(source);
        if (sourceBlock) CFRelease(sourceBlock);
        return NULL;
    }

    const size_t sampleBytes = bytesFor(kind);
    UInt32 totalChannels = 0;
    for (UInt32 b = 0; b < source->mNumberBuffers; ++b) {
        const AudioBuffer &buffer = source->mBuffers[b];
        const UInt32 bufferChannels = MAX((UInt32)1, buffer.mNumberChannels);
        if (!buffer.mData || buffer.mDataByteSize < (size_t)frames * bufferChannels * sampleBytes) {
            free(source);
            CFRelease(sourceBlock);
            return NULL;
        }
        totalChannels += bufferChannels;
    }
    if (totalChannels != channels) {
        free(source);
        CFRelease(sourceBlock);
        return NULL;
    }

    // Planar float scratch, one row per channel.
    std::vector<float> scratch((size_t)channels * (size_t)frames);
    float *rows[micfilter::kMaxChannels];
    for (UInt32 ch = 0; ch < channels; ++ch) rows[ch] = scratch.data() + (size_t)ch * (size_t)frames;

    UInt32 channelBase = 0;
    for (UInt32 b = 0; b < source->mNumberBuffers; ++b) {
        const AudioBuffer &buffer = source->mBuffers[b];
        const UInt32 bufferChannels = MAX((UInt32)1, buffer.mNumberChannels);
        for (CMItemCount f = 0; f < frames; ++f) {
            for (UInt32 c = 0; c < bufferChannels; ++c) {
                rows[channelBase + c][f] = readSample(buffer.mData, (size_t)f * bufferChannels + c, kind);
            }
        }
        channelBase += bufferChannels;
    }

    os_unfair_lock_lock(&g_micFilterLock);
    g_micFilterChain.process(rows, (int)channels, (long)frames);
    os_unfair_lock_unlock(&g_micFilterLock);

    AudioBufferList *output = (AudioBufferList *)calloc(1, listSize);
    if (!output) {
        free(source);
        CFRelease(sourceBlock);
        return NULL;
    }
    output->mNumberBuffers = source->mNumberBuffers;
    channelBase = 0;
    bool allocationFailed = false;
    for (UInt32 b = 0; b < source->mNumberBuffers; ++b) {
        const AudioBuffer &in = source->mBuffers[b];
        AudioBuffer &out = output->mBuffers[b];
        const UInt32 bufferChannels = MAX((UInt32)1, in.mNumberChannels);
        out.mNumberChannels = in.mNumberChannels;
        out.mDataByteSize = (UInt32)((size_t)frames * bufferChannels * sampleBytes);
        out.mData = malloc(out.mDataByteSize);
        if (!out.mData) { allocationFailed = true; break; }
        for (CMItemCount f = 0; f < frames; ++f) {
            for (UInt32 c = 0; c < bufferChannels; ++c) {
                writeSample(out.mData, (size_t)f * bufferChannels + c, kind, rows[channelBase + c][f]);
            }
        }
        channelBase += bufferChannels;
    }
    free(source);
    CFRelease(sourceBlock);
    if (allocationFailed) {
        freeBufferList(output, true);
        return NULL;
    }

    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing) != noErr) {
        timing.duration = CMTimeMake(1, (int32_t)llround(asbd->mSampleRate));
        timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef result = NULL;
    status = CMSampleBufferCreate(kCFAllocatorDefault, NULL, false, NULL, NULL,
                                  format, frames, 1, &timing, 0, NULL, &result);
    if (status == noErr && result) {
        status = CMSampleBufferSetDataBufferFromAudioBufferList(result, kCFAllocatorDefault,
                                                                kCFAllocatorDefault, 0, output);
        if (status == noErr && !CMSampleBufferDataIsReady(result)) {
            status = CMSampleBufferSetDataReady(result);
        }
    }
    freeBufferList(output, true);

    if (status != noErr || !result) {
        static int failureCount = 0;
        if (failureCount++ % 200 == 0) {
            MRLog(@"⚠️ Mic filters: could not build filtered buffer (status %d); writing unfiltered audio", (int)status);
        }
        if (result) CFRelease(result);
        return NULL;
    }
    return result;
}
