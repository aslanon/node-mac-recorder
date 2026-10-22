// Real-time microphone filter chain (OBS style) for the recorded mic track.
//
// Chain: Noise Gate -> Expander -> 3-Band EQ (+ low cut) -> Compressor -> Limiter.
// Level detection is linked across channels.
//
// Pure C++ (no Apple frameworks) so it can be unit tested anywhere. The desktop
// app runs a 1:1 JavaScript port (desktop/utils/micFilterDsp.mjs) for the live
// monitor in Settings; keep the two in sync.
#ifndef MIC_FILTER_DSP_H
#define MIC_FILTER_DSP_H

#include <algorithm>
#include <cmath>
#include <vector>

namespace micfilter {

static const int kMaxChannels = 8;
static const double kGateDetectorMs = 20.0;
static const double kExpanderFloorDb = -60.0;
static const double kSilence = 1e-9;

struct GateConfig { bool enabled = false; double closeThresholdDb = -50, openThresholdDb = -44, attackMs = 5, holdMs = 200, releaseMs = 150; };
struct ExpanderConfig { bool enabled = false; double thresholdDb = -45, ratio = 2, attackMs = 10, releaseMs = 80; };
struct EqConfig { bool enabled = false; double lowCutHz = 0, lowFreqHz = 150, lowGainDb = 0, midFreqHz = 3000, midGainDb = 0, highFreqHz = 9000, highGainDb = 0; };
struct CompressorConfig { bool enabled = false; double thresholdDb = -20, ratio = 3, attackMs = 6, releaseMs = 80, makeupDb = 0; };
struct LimiterConfig { bool enabled = false; double thresholdDb = -1.5, releaseMs = 60; };

struct Config {
    bool enabled = false;
    GateConfig gate;
    ExpanderConfig expander;
    EqConfig eq;
    CompressorConfig compressor;
    LimiterConfig limiter;
};

inline double coef(double ms, double sampleRate) {
    if (!(ms > 0)) return 0.0;
    return std::exp(-1000.0 / (ms * sampleRate));
}
inline double dbToLin(double db) { return std::pow(10.0, db / 20.0); }
inline double linToDb(double lin) { return 20.0 * std::log10(lin + kSilence); }

enum class BiquadType { HighPass, LowShelf, Peaking, HighShelf };

// RBJ Audio EQ Cookbook biquad, direct form I.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double x1[kMaxChannels] = {0}, x2[kMaxChannels] = {0}, y1[kMaxChannels] = {0}, y2[kMaxChannels] = {0};

    Biquad(BiquadType type, double freq, double gainDb, double q, double sampleRate) {
        const double pi = 3.14159265358979323846;
        const double nyquistSafe = sampleRate * 0.45;
        const double f = std::min(std::max(freq, 10.0), nyquistSafe);
        const double w0 = (2.0 * pi * f) / sampleRate;
        const double cosW = std::cos(w0);
        const double sinW = std::sin(w0);
        const double A = std::pow(10.0, gainDb / 40.0);
        double nb0, nb1, nb2, na0, na1, na2;
        if (type == BiquadType::HighPass) {
            const double alpha = sinW / (2.0 * q);
            nb0 = (1 + cosW) / 2; nb1 = -(1 + cosW); nb2 = (1 + cosW) / 2;
            na0 = 1 + alpha; na1 = -2 * cosW; na2 = 1 - alpha;
        } else if (type == BiquadType::Peaking) {
            const double alpha = sinW / (2.0 * q);
            nb0 = 1 + alpha * A; nb1 = -2 * cosW; nb2 = 1 - alpha * A;
            na0 = 1 + alpha / A; na1 = -2 * cosW; na2 = 1 - alpha / A;
        } else {
            const double alpha = (sinW / 2.0) * std::sqrt(2.0);
            const double twoSqrtAAlpha = 2.0 * std::sqrt(A) * alpha;
            if (type == BiquadType::LowShelf) {
                nb0 = A * ((A + 1) - (A - 1) * cosW + twoSqrtAAlpha);
                nb1 = 2 * A * ((A - 1) - (A + 1) * cosW);
                nb2 = A * ((A + 1) - (A - 1) * cosW - twoSqrtAAlpha);
                na0 = (A + 1) + (A - 1) * cosW + twoSqrtAAlpha;
                na1 = -2 * ((A - 1) + (A + 1) * cosW);
                na2 = (A + 1) + (A - 1) * cosW - twoSqrtAAlpha;
            } else {
                nb0 = A * ((A + 1) + (A - 1) * cosW + twoSqrtAAlpha);
                nb1 = -2 * A * ((A - 1) + (A + 1) * cosW);
                nb2 = A * ((A + 1) + (A - 1) * cosW - twoSqrtAAlpha);
                na0 = (A + 1) - (A - 1) * cosW + twoSqrtAAlpha;
                na1 = 2 * ((A - 1) - (A + 1) * cosW);
                na2 = (A + 1) - (A - 1) * cosW - twoSqrtAAlpha;
            }
        }
        b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0; a1 = na1 / na0; a2 = na2 / na0;
    }

    inline double run(int ch, double x) {
        const double y = b0 * x + b1 * x1[ch] + b2 * x2[ch] - a1 * y1[ch] - a2 * y2[ch];
        x2[ch] = x1[ch]; x1[ch] = x;
        y2[ch] = y1[ch]; y1[ch] = y;
        return y;
    }

    void reset() {
        for (int i = 0; i < kMaxChannels; ++i) { x1[i] = x2[i] = y1[i] = y2[i] = 0; }
    }
};

class Chain {
public:
    Chain() { configure(Config(), 48000.0); }

    void configure(const Config &c, double sampleRate) {
        const double sr = sampleRate > 0 ? sampleRate : 48000.0;
        sampleRate_ = sr;
        config_ = c;
        enabled_ = c.enabled;

        gateOn_ = c.gate.enabled;
        gateClose_ = dbToLin(c.gate.closeThresholdDb);
        gateOpen_ = dbToLin(std::max(c.gate.openThresholdDb, c.gate.closeThresholdDb));
        gateAttackStep_ = 1.0 / std::max(1.0, (c.gate.attackMs * sr) / 1000.0);
        gateReleaseStep_ = 1.0 / std::max(1.0, (c.gate.releaseMs * sr) / 1000.0);
        gateHoldSamples_ = (long)std::llround((std::max(0.0, c.gate.holdMs) * sr) / 1000.0);
        gateDetectorCoef_ = coef(kGateDetectorMs, sr);

        expOn_ = c.expander.enabled;
        expThresholdDb_ = c.expander.thresholdDb;
        expRatio_ = std::max(1.0, c.expander.ratio);
        expAttack_ = coef(c.expander.attackMs, sr);
        expRelease_ = coef(c.expander.releaseMs, sr);

        eqOn_ = c.eq.enabled;
        eq_.clear();
        if (eqOn_) {
            if (c.eq.lowCutHz >= 20) eq_.emplace_back(BiquadType::HighPass, c.eq.lowCutHz, 0.0, std::sqrt(0.5), sr);
            if (c.eq.lowGainDb != 0) eq_.emplace_back(BiquadType::LowShelf, c.eq.lowFreqHz, c.eq.lowGainDb, 0.0, sr);
            if (c.eq.midGainDb != 0) eq_.emplace_back(BiquadType::Peaking, c.eq.midFreqHz, c.eq.midGainDb, 0.9, sr);
            if (c.eq.highGainDb != 0) eq_.emplace_back(BiquadType::HighShelf, c.eq.highFreqHz, c.eq.highGainDb, 0.0, sr);
        }

        compOn_ = c.compressor.enabled;
        compThresholdDb_ = c.compressor.thresholdDb;
        compRatio_ = std::max(1.0, c.compressor.ratio);
        compAttack_ = coef(c.compressor.attackMs, sr);
        compRelease_ = coef(c.compressor.releaseMs, sr);
        compMakeup_ = dbToLin(c.compressor.makeupDb);

        limOn_ = c.limiter.enabled;
        limThreshold_ = dbToLin(c.limiter.thresholdDb);
        limRelease_ = coef(c.limiter.releaseMs, sr);

        reset();
    }

    void reset() {
        gateEnv_ = 0; gateIsOpen_ = false; gateGain_ = 0; gateHeld_ = 0;
        expEnv_ = 0; compEnv_ = 0; limGain_ = 1;
        for (auto &bq : eq_) bq.reset();
    }

    double sampleRate() const { return sampleRate_; }
    const Config &config() const { return config_; }

    bool active() const {
        return enabled_ && (gateOn_ || expOn_ || eqOn_ || compOn_ || limOn_);
    }

    // Planar float channels, processed in place.
    void process(float **channels, int channelCount, long frames) {
        channelCount = std::min(channelCount, kMaxChannels);
        if (!active() || channelCount <= 0 || !channels) return;
        for (long i = 0; i < frames; ++i) {
            double peak = 0;
            for (int ch = 0; ch < channelCount; ++ch) {
                const double a = std::fabs((double)channels[ch][i]);
                if (a > peak) peak = a;
            }
            double gain = 1;

            if (gateOn_) {
                gateEnv_ = std::max(gateEnv_ * gateDetectorCoef_, peak);
                if (!gateIsOpen_ && gateEnv_ >= gateOpen_) {
                    gateIsOpen_ = true;
                } else if (gateIsOpen_ && gateEnv_ < gateClose_) {
                    gateIsOpen_ = false;
                    gateHeld_ = 0;
                }
                if (gateIsOpen_) {
                    gateGain_ = std::min(1.0, gateGain_ + gateAttackStep_);
                } else if (gateHeld_ < gateHoldSamples_) {
                    gateHeld_++;
                } else {
                    gateGain_ = std::max(0.0, gateGain_ - gateReleaseStep_);
                }
                gain *= gateGain_;
            }

            if (expOn_) {
                const double level = peak * gain;
                const double c = level > expEnv_ ? expAttack_ : expRelease_;
                expEnv_ = c * expEnv_ + (1 - c) * level;
                const double levelDb = linToDb(expEnv_);
                if (levelDb < expThresholdDb_) {
                    const double reductionDb = std::max(kExpanderFloorDb, (levelDb - expThresholdDb_) * (expRatio_ - 1));
                    gain *= dbToLin(reductionDb);
                }
            }

            const double preGain = gain;
            for (int ch = 0; ch < channelCount; ++ch) {
                double s = (double)channels[ch][i] * preGain;
                for (auto &bq : eq_) s = bq.run(ch, s);
                channels[ch][i] = (float)s;
            }

            double postGain = 1;
            if (compOn_ || limOn_) {
                double post = 0;
                for (int ch = 0; ch < channelCount; ++ch) {
                    const double a = std::fabs((double)channels[ch][i]);
                    if (a > post) post = a;
                }
                if (compOn_) {
                    const double c = post > compEnv_ ? compAttack_ : compRelease_;
                    compEnv_ = c * compEnv_ + (1 - c) * post;
                    const double overDb = linToDb(compEnv_) - compThresholdDb_;
                    const double reductionDb = overDb > 0 ? overDb * (1 - 1 / compRatio_) : 0;
                    postGain = dbToLin(-reductionDb) * compMakeup_;
                }
                if (limOn_) {
                    const double level = post * postGain;
                    const double required = level > limThreshold_ ? limThreshold_ / level : 1;
                    const double released = limRelease_ * limGain_ + (1 - limRelease_);
                    limGain_ = std::min(required, released);
                    postGain *= limGain_;
                }
            }

            for (int ch = 0; ch < channelCount; ++ch) {
                double s = (double)channels[ch][i] * postGain;
                if (s > 1) s = 1; else if (s < -1) s = -1;
                channels[ch][i] = (float)s;
            }
        }
    }

private:
    double sampleRate_ = 48000;
    Config config_;
    bool enabled_ = false;

    bool gateOn_ = false;
    double gateClose_ = 0, gateOpen_ = 0, gateAttackStep_ = 1, gateReleaseStep_ = 1, gateDetectorCoef_ = 0;
    long gateHoldSamples_ = 0, gateHeld_ = 0;
    double gateEnv_ = 0, gateGain_ = 0;
    bool gateIsOpen_ = false;

    bool expOn_ = false;
    double expThresholdDb_ = -45, expRatio_ = 2, expAttack_ = 0, expRelease_ = 0, expEnv_ = 0;

    bool eqOn_ = false;
    std::vector<Biquad> eq_;

    bool compOn_ = false;
    double compThresholdDb_ = -20, compRatio_ = 3, compAttack_ = 0, compRelease_ = 0, compMakeup_ = 1, compEnv_ = 0;

    bool limOn_ = false;
    double limThreshold_ = 1, limRelease_ = 0, limGain_ = 1;
};

} // namespace micfilter

#endif // MIC_FILTER_DSP_H
