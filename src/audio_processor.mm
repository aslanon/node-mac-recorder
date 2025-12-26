#import "audio_processor.h"
#import "logging.h"
#import <Accelerate/Accelerate.h>
#include <math.h>

// Processor state
static Float32 g_currentGain = 1.0f;
static Float32 g_envelopeLevel = 0.0f;
static UInt32 g_holdCounter = 0;
static BOOL g_processorInitialized = NO;

// Algorithm parameters (tuned for keyboard/mouse click detection)
static const Float32 kNoiseThreshold = 0.008f;      // -42 dB: Clicks below this are likely noise
static const Float32 kVoiceThreshold = 0.02f;       // -34 dB: Voice is typically above this
static const Float32 kAttackTime = 0.001f;          // 1ms: Fast attack to catch transients
static const Float32 kReleaseTime = 0.050f;         // 50ms: Smooth release to avoid cutting voice
static const Float32 kHoldTime = 0.020f;            // 20ms: Hold time before release starts
static const Float32 kNoiseReductionAmount = 0.15f; // Reduce clicks to 15% volume (-16.5 dB)

// Calculated coefficients (updated based on sample rate)
static Float32 g_attackCoeff = 0.0f;
static Float32 g_releaseCoeff = 0.0f;
static UInt32 g_holdSamples = 0;
static Float32 g_sampleRate = 48000.0f;

/**
 * Initialize or update coefficients based on sample rate
 */
static void updateProcessorCoefficients(Float32 sampleRate) {
    if (sampleRate <= 0.0f) {
        sampleRate = 48000.0f; // Default
    }

    if (fabsf(g_sampleRate - sampleRate) > 0.1f) {
        g_sampleRate = sampleRate;

        // Exponential attack/release coefficients
        // coeff = exp(-1.0 / (time * sampleRate))
        g_attackCoeff = expf(-1.0f / (kAttackTime * sampleRate));
        g_releaseCoeff = expf(-1.0f / (kReleaseTime * sampleRate));
        g_holdSamples = (UInt32)(kHoldTime * sampleRate);

        MRLog(@"🎛️ Audio Processor: Initialized for %.0f Hz (attack=%.4f, release=%.4f, hold=%u samples)",
              sampleRate, g_attackCoeff, g_releaseCoeff, g_holdSamples);
    }
}

void resetAudioProcessorState(void) {
    g_currentGain = 1.0f;
    g_envelopeLevel = 0.0f;
    g_holdCounter = 0;
    g_processorInitialized = NO;
    MRLog(@"🔄 Audio Processor: State reset");
}

/**
 * Calculate RMS (Root Mean Square) level of audio buffer
 */
static Float32 calculateRMS(const Float32 *samples, UInt32 numSamples) {
    if (!samples || numSamples == 0) {
        return 0.0f;
    }

    Float32 sum = 0.0f;
    vDSP_svesq(samples, 1, &sum, numSamples); // Sum of squares (using Accelerate framework)
    return sqrtf(sum / (Float32)numSamples);
}

/**
 * Apply gain to audio samples (in-place)
 */
static void applySmoothGain(Float32 *samples, UInt32 numSamples, Float32 targetGain, Float32 *currentGain) {
    if (!samples || numSamples == 0) {
        return;
    }

    // Smooth gain interpolation to avoid clicks
    Float32 gainStep = (targetGain - *currentGain) / (Float32)numSamples;

    for (UInt32 i = 0; i < numSamples; i++) {
        *currentGain += gainStep;
        samples[i] *= *currentGain;
    }
}

/**
 * Detect if audio contains a transient (click/pop)
 * Transients have very short duration (<20ms) and high amplitude
 */
static BOOL isTransientSound(Float32 rmsLevel, Float32 peakLevel, Float32 *envelope) {
    // Update envelope (peak follower with fast attack, slow release)
    Float32 coeff = (rmsLevel > *envelope) ? g_attackCoeff : g_releaseCoeff;
    *envelope = coeff * (*envelope) + (1.0f - coeff) * rmsLevel;

    // Transient detection: Sudden spike above envelope
    Float32 ratio = (*envelope > 0.001f) ? (rmsLevel / *envelope) : 1.0f;

    // If RMS suddenly increases by >3x and is in noise range, likely a click
    BOOL isSuddenSpike = (ratio > 3.0f) && (rmsLevel > kNoiseThreshold) && (rmsLevel < kVoiceThreshold);

    return isSuddenSpike;
}

BOOL processAudioBufferForNoiseReduction(CMSampleBufferRef sampleBuffer,
                                          CMSampleBufferRef *outputBuffer,
                                          Float32 sensitivity) {
    if (!sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) {
        return NO;
    }

    // Set output to NULL - we're not modifying the buffer yet, just analyzing
    if (outputBuffer) {
        *outputBuffer = NULL;
    }

    // Get audio buffer list for analysis only (read-only)
    AudioBufferList audioBufferList;
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        &audioBufferList,
        sizeof(audioBufferList),
        NULL,
        NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &blockBuffer
    );

    if (status != noErr || !blockBuffer) {
        return YES; // Still return success, just skip analysis
    }

    // Get format description
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);

    if (!asbd) {
        CFRelease(blockBuffer);
        return NO;
    }

    // Initialize coefficients if needed
    if (!g_processorInitialized) {
        updateProcessorCoefficients(asbd->mSampleRate);
        g_processorInitialized = YES;
    }

    // Process each channel
    for (UInt32 i = 0; i < audioBufferList.mNumberBuffers; i++) {
        AudioBuffer *buffer = &audioBufferList.mBuffers[i];

        if (!buffer->mData || buffer->mDataByteSize == 0) {
            continue;
        }

        // Determine format and get sample count
        UInt32 numSamples = 0;
        Float32 *floatSamples = NULL;
        SInt16 *int16Samples = NULL;
        BOOL needsConversion = NO;

        if (asbd->mFormatFlags & kAudioFormatFlagIsFloat) {
            // Already float
            floatSamples = (Float32 *)buffer->mData;
            numSamples = buffer->mDataByteSize / sizeof(Float32);
        } else if (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) {
            // 16-bit integer - convert to float for processing
            int16Samples = (SInt16 *)buffer->mData;
            numSamples = buffer->mDataByteSize / sizeof(SInt16);
            floatSamples = (Float32 *)malloc(numSamples * sizeof(Float32));
            needsConversion = YES;

            // Convert int16 to float32
            for (UInt32 j = 0; j < numSamples; j++) {
                floatSamples[j] = int16Samples[j] / 32768.0f;
            }
        } else {
            continue; // Unsupported format
        }

        if (!floatSamples || numSamples == 0) {
            if (needsConversion && floatSamples) {
                free(floatSamples);
            }
            continue;
        }

        // Calculate audio levels (analysis only - not modifying buffer)
        Float32 rmsLevel = calculateRMS(floatSamples, numSamples);
        Float32 peakLevel = 0.0f;
        vDSP_maxmgv(floatSamples, 1, &peakLevel, numSamples);

        // Detect transients (clicks/pops)
        BOOL isClick = isTransientSound(rmsLevel, peakLevel, &g_envelopeLevel);

        // Calculate what gain would be applied (for logging only)
        Float32 targetGain = 1.0f;

        if (rmsLevel < kNoiseThreshold * sensitivity) {
            targetGain = kNoiseReductionAmount;
            g_holdCounter = 0;
        } else if (isClick) {
            targetGain = kNoiseReductionAmount;
            g_holdCounter = g_holdSamples;
        } else if (g_holdCounter > 0) {
            targetGain = kNoiseReductionAmount;
            g_holdCounter = (g_holdCounter > numSamples) ? (g_holdCounter - numSamples) : 0;
        } else if (rmsLevel > kVoiceThreshold) {
            targetGain = 1.0f;
        } else {
            Float32 ratio = (rmsLevel - kNoiseThreshold * sensitivity) / (kVoiceThreshold - kNoiseThreshold * sensitivity);
            ratio = fmaxf(0.0f, fminf(1.0f, ratio));
            targetGain = kNoiseReductionAmount + ratio * (1.0f - kNoiseReductionAmount);
        }

        // Log detection for debugging
        static int logCounter = 0;
        if (isClick && (logCounter++ % 10 == 0)) {
            MRLog(@"🔊 Click detected: RMS=%.4f Peak=%.4f TargetGain=%.2f", rmsLevel, peakLevel, targetGain);
        }

        // Clean up temporary buffer if needed
        if (needsConversion && floatSamples) {
            free(floatSamples);
        }
    }

    CFRelease(blockBuffer);
    return YES;
}
