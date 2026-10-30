#include "webrtc_aec3_shim.h"

#include "api/audio/audio_processing.h"
#include "api/audio/echo_control.h"
#include "api/audio/echo_canceller3_config.h"
#include "api/scoped_refptr.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"

using webrtc::AudioProcessing;
using webrtc::AudioProcessingBuilder;
using webrtc::StreamConfig;

struct WebRTCAEC3State {
    rtc::scoped_refptr<AudioProcessing> apm;
    int sampleRateHz;
    int renderChannels;
    StreamConfig renderConfig;
    StreamConfig captureConfig;
    // ProcessReverseStream/ProcessStream take deinterleaved `const float* const*`
    // channel pointers; these hold per-channel buffers reused across calls so
    // the hot path never allocates.
    std::vector<std::vector<float>> renderChannelBuffers;
    std::vector<float *> renderChannelPointers;
    std::vector<float> captureChannelBuffer;
    float *captureChannelPointer;
};

// EchoCanceller3's default `dominant_nearend_detection` thresholds (tuned for WebRTC's own
// call scenarios) suppress near-end speech more than this app's "preserve the talker during
// double talk" requirement wants when the echo and near-end are comparable in level. Lowering
// `snr_threshold` makes AEC3 switch to its gentler `nearend_tuning` suppression curve (instead
// of `normal_tuning`) at a lower near-end-to-residual-noise ratio, so it recognizes double talk
// sooner and backs off suppression instead of attenuating the talker along with the echo.
static webrtc::EchoCanceller3Config makeEchoCanceller3Config() {
    webrtc::EchoCanceller3Config config;
    // Lower thresholds than AEC3's defaults (snr_threshold 30, enr_threshold .25): makes AEC3
    // classify a frame as "dominant nearend" (double talk) sooner, switching to its gentler
    // `nearend_tuning` suppression curve instead of `normal_tuning` more readily. Verified
    // empirically against EchoCancellerTests' double-talk scenario (improves near-end
    // preservation from -10.6 dB to -6.85 dB vs. AEC3's defaults; still short of the 3 dB
    // target -- see CWebRTCAEC/README.md for the full account).
    config.suppressor.dominant_nearend_detection.snr_threshold = 5.0f;
    config.suppressor.dominant_nearend_detection.enr_threshold = 1.0f;
    config.suppressor.dominant_nearend_detection.hold_duration = 25;
    config.suppressor.dominant_nearend_detection.trigger_threshold = 3;
    return config;
}

namespace {
class TunedEchoCanceller3Factory : public webrtc::EchoControlFactory {
 public:
    std::unique_ptr<webrtc::EchoControl> Create(int sampleRateHz, int numRenderChannels,
                                                int numCaptureChannels) override {
        return std::make_unique<webrtc::EchoCanceller3>(
            makeEchoCanceller3Config(), std::nullopt, sampleRateHz,
            static_cast<size_t>(numRenderChannels), static_cast<size_t>(numCaptureChannels));
    }
};
} // namespace

static rtc::scoped_refptr<AudioProcessing> makeAPM() {
    AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.high_pass_filter.enabled = true;
    // Everything else (AGC1/2, noise suppression, pre-amplifier, level
    // adjustment) stays at its default `enabled = false`.
    return AudioProcessingBuilder()
        .SetConfig(config)
        .SetEchoControlFactory(std::make_unique<TunedEchoCanceller3Factory>())
        .Create();
}

extern "C" WebRTCAEC3State *webrtc_aec3_create(int sampleRateHz, int renderChannels) {
    if (sampleRateHz <= 0 || renderChannels <= 0) return nullptr;
    auto apm = makeAPM();
    if (!apm) return nullptr;

    auto *state = new WebRTCAEC3State();
    state->apm = apm;
    state->sampleRateHz = sampleRateHz;
    state->renderChannels = renderChannels;
    state->renderConfig = StreamConfig(sampleRateHz, static_cast<size_t>(renderChannels));
    state->captureConfig = StreamConfig(sampleRateHz, 1);

    const size_t frames = state->renderConfig.num_frames();
    state->renderChannelBuffers.assign(static_cast<size_t>(renderChannels), std::vector<float>(frames, 0.0f));
    state->renderChannelPointers.resize(static_cast<size_t>(renderChannels));
    for (int c = 0; c < renderChannels; ++c) {
        state->renderChannelPointers[static_cast<size_t>(c)] = state->renderChannelBuffers[static_cast<size_t>(c)].data();
    }
    state->captureChannelBuffer.assign(frames, 0.0f);
    state->captureChannelPointer = state->captureChannelBuffer.data();

    return state;
}

extern "C" void webrtc_aec3_destroy(WebRTCAEC3State *state) {
    delete state;
}

extern "C" void webrtc_aec3_set_stream_delay_ms(WebRTCAEC3State *state, int delayMs) {
    if (!state || !state->apm) return;
    state->apm->set_stream_delay_ms(delayMs);
}

extern "C" bool webrtc_aec3_process_reverse_stream(WebRTCAEC3State *state, const float *render) {
    if (!state || !state->apm) return false;
    const size_t frames = state->renderConfig.num_frames();
    const int channels = state->renderChannels;
    for (size_t i = 0; i < frames; ++i) {
        for (int c = 0; c < channels; ++c) {
            state->renderChannelBuffers[static_cast<size_t>(c)][i] = render[i * static_cast<size_t>(channels) + static_cast<size_t>(c)];
        }
    }
    int result = state->apm->ProcessReverseStream(state->renderChannelPointers.data(), state->renderConfig,
                                                    state->renderConfig, state->renderChannelPointers.data());
    return result == AudioProcessing::kNoError;
}

extern "C" bool webrtc_aec3_process_stream(WebRTCAEC3State *state, float *capture) {
    if (!state || !state->apm) return false;
    const size_t frames = state->captureConfig.num_frames();
    for (size_t i = 0; i < frames; ++i) {
        state->captureChannelBuffer[i] = capture[i];
    }
    int result = state->apm->ProcessStream(&state->captureChannelPointer, state->captureConfig,
                                            state->captureConfig, &state->captureChannelPointer);
    if (result != AudioProcessing::kNoError) return false;
    for (size_t i = 0; i < frames; ++i) {
        capture[i] = state->captureChannelBuffer[i];
    }
    return true;
}

extern "C" void webrtc_aec3_reset(WebRTCAEC3State *state) {
    if (!state) return;
    // AudioProcessing exposes no public "reset adaptive state" call; the
    // documented way is to re-create the instance with the same config.
    state->apm = makeAPM();
}

extern "C" int webrtc_aec3_frame_size(int sampleRateHz) {
    return AudioProcessing::GetFrameSize(sampleRateHz);
}
