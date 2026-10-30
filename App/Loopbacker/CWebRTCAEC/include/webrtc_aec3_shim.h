// A pure-C bridge to webrtc::AudioProcessing configured for AEC3-only use
// (echo canceller + high-pass filter; AGC/NS/VAD left disabled at runtime even
// though their object code is statically linked in, since AudioProcessingImpl
// constructs them unconditionally). Lets Swift drive the C++ API without
// exposing any C++ types across the module boundary.
#ifndef WEBRTC_AEC3_SHIM_H
#define WEBRTC_AEC3_SHIM_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WebRTCAEC3State WebRTCAEC3State;

// Creates an AudioProcessing instance with only the echo canceller and
// high-pass filter enabled, for `sampleRateHz` (typically 48000) and
// `renderChannels` (1 or 2) render reference channels, mono capture.
// Returns NULL on failure.
WebRTCAEC3State *webrtc_aec3_create(int sampleRateHz, int renderChannels);

void webrtc_aec3_destroy(WebRTCAEC3State *state);

// Sets the expected delay in ms between a render frame reaching
// ProcessReverseStream and the matching capture frame (containing that
// frame's echo) reaching ProcessStream. AEC3 uses this as a starting point
// and refines it internally; a generous estimate is fine.
void webrtc_aec3_set_stream_delay_ms(WebRTCAEC3State *state, int delayMs);

// Feeds one 10 ms render (far-end reference) frame, interleaved float,
// `renderChannels` channels as passed to `webrtc_aec3_create`, length
// frameSize(sampleRateHz) * renderChannels. Returns false on failure.
bool webrtc_aec3_process_reverse_stream(WebRTCAEC3State *state, const float *render);

// Cancels echo from one 10 ms mono capture frame in place, length
// frameSize(sampleRateHz). Returns false on failure.
bool webrtc_aec3_process_stream(WebRTCAEC3State *state, float *capture);

// Resets the echo canceller's adaptive state (re-creates the AEC3 instance).
void webrtc_aec3_reset(WebRTCAEC3State *state);

// Frame size (samples per channel) AudioProcessing expects per call at
// `sampleRateHz` -- 10 ms worth, e.g. 480 at 48 kHz.
int webrtc_aec3_frame_size(int sampleRateHz);

#ifdef __cplusplus
}
#endif

#endif // WEBRTC_AEC3_SHIM_H
