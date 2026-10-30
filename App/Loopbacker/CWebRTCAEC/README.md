# CWebRTCAEC

Vendored subset of [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing)
(the freedesktop/PulseAudio fork of Chromium's WebRTC audio processing module), tag `v2.1`
(commit `846fe90a289f58b7c9303a635142aa2c7caa93e5`, 2025-01-22), plus the `abseil-cpp` subset it
pulls in transitively (pinned by the project's own `subprojects/abseil-cpp.wrap` to
`20240722.0`). License: both BSD-3-Clause (`LICENSE-webrtc-audio-processing.txt`, copied
verbatim from upstream `COPYING`) and Apache-2.0 (`LICENSE-abseil.txt`, copied verbatim from
abseil's `LICENSE`).

This is the *second* attempt at a WebRTC echo canceller for this app — the first (see
`../CSpeexAEC/README.md`, now removed) judged full GN/Bazel-style vendoring infeasible by hand
and fell back to SpeexDSP's MDF. That fallback shipped and worked, but is linear-only: no
residual echo suppressor, no delay estimator (the ring's own latency became a hard floor on
what delay MDF could cancel), and no clock-drift handling beyond what `DriftCompensatedRing`
already does. AEC3 has all three, which matters for real (nonlinear) laptop/phone speakers.

## How this was actually vendored (mechanically, not by hand)

Hand-reconstructing GN's dependency graph was what sank the first attempt. This time:

1. `brew install meson ninja` (arm64 Homebrew — x86_64 Homebrew's `meson`/`ninja` under Rosetta
   fail with "Bad CPU type"; use `/opt/homebrew/bin`, not `/usr/local/bin`).
2. `git clone --branch v2.1 https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git`.
   The project's own `meson.build` + `subprojects/abseil-cpp.wrap` already describe its real
   build graph, including fetching exactly the abseil subset it needs (meson's wrap mechanism
   downloads `abseil-cpp-20240722.0` and applies the WrapDB `cmake`→`meson` patch automatically).
3. `meson setup build --default-library=static --buildtype=release && ninja -C build` — builds
   cleanly out of the box, no manual configuration beyond disabling nothing (there's no meson
   option to exclude AGC/NS from the apm library; it's one monolithic static lib — see below).
4. `generate.py` (in this directory) then uses `ninja -t query` on the final apm static library
   target to get every object file meson folded into it (this flattens `rtc_base`, `api`,
   `system_wrappers`, `common_audio`, `third_party/{fft,pffft,rnnoise}`, and the relevant
   abseil static libs — meson statically links all of these *into* the apm archive, not just
   alongside it), `ninja -t compdb` for the exact compiler defines/include paths used, and
   `ninja -t deps` (clang's dependency info that ninja already collected during the build) for
   the exact set of project headers each object actually included. All three are ground truth
   from the real build, not a hand-maintained list.

Re-running `generate.py` against a fresh meson build is how to pick up a new upstream tag.

## Why the AGC/NS/VAD code is in here too

`AudioProcessingImpl` (the class behind the public `webrtc::AudioProcessing` interface) is
monolithic: its constructor and `ApplyConfig` unconditionally construct the AGC1/AGC2/noise
suppression/VAD submodules whether or not they're enabled in `AudioProcessing::Config` — they
just sit idle if their `enabled` flag is false. There is no meson option or `#ifdef` to compile
just the echo-canceller slice of `audio_processing_impl.cc`'s own dependency closure out; doing
so would mean forking `AudioProcessingImpl` itself, which trades "vendor some unused code" for
"maintain a divergent fork of WebRTC's own glue code." `shim/webrtc_aec3_shim.cpp` only enables
`echo_canceller` and `high_pass_filter` in the `AudioProcessing::Config` passed at construction
(see `makeEchoCanceller3Config`/`makeAPM`), so AGC/NS/VAD never run, but their object code is
present. 368 source files total: 244 from webrtc-audio-processing (apm, rtc_base, api,
system_wrappers, common_audio, third_party/{fft,pffft,rnnoise}, plus the ISAC filter-function
`.c` files `common_audio/vad/` depends on), 124 from abseil (base, strings, container,
synchronization, time, types, hash, numeric, flags, debugging, random, status, log, crc,
profiling — abseil's own library granularity doesn't let meson cherry-pick individual
functions either, so depending on `absl_flags` for one helper pulls in all of
`absl::flags_internal`, etc.).

## Shim (`shim/`, `include/webrtc_aec3_shim.h`)

A small C API wrapping `webrtc::AudioProcessing` so `EchoCanceller.swift` never needs C++
interop:

- `webrtc_aec3_create(sampleRateHz, renderChannels)` — builds an `AudioProcessing` instance via
  `AudioProcessingBuilder`, injecting a custom `EchoControlFactory`
  (`TunedEchoCanceller3Factory`) that constructs `webrtc::EchoCanceller3` directly with a
  tuned `EchoCanceller3Config` (see "Double-talk tuning" below) instead of AEC3's stock
  defaults, which the default `Config::EchoCanceller.enabled = true` path can't reach (that
  path always uses `EchoCanceller3Config{}` — see `audio_processing_impl.cc`'s
  `InitializeEchoController`).
- `webrtc_aec3_process_reverse_stream`/`webrtc_aec3_process_stream` — deinterleave into
  preallocated per-channel buffers (sized once at `create` time) and call
  `ProcessReverseStream`/`ProcessStream`, in place.
- `webrtc_aec3_set_stream_delay_ms` — AEC3 estimates and tracks the actual render/capture delay
  continuously; this only supplies a starting point.
- `webrtc_aec3_reset` — `AudioProcessing` has no public "reset adaptive state" call, so this
  re-creates the instance (same pattern as rebuilding a fresh `EchoCanceller3`).

## Double-talk tuning

AEC3's stock `suppressor.dominant_nearend_detection` thresholds (`snr_threshold = 30`,
`enr_threshold = .25`) are tuned for WebRTC's own call scenarios and, in this app's synthetic
double-talk test (near-end voice comparable in level to the far-end echo), suppress the
near-end talker by about 10.6 dB more than the 3 dB target during double talk — `EchoCanceller`
previously (with MDF) met that target, since MDF's 2-path design keeps a near-untouched
"foreground" filter ready as a fallback. `makeEchoCanceller3Config()` lowers `snr_threshold` to
5 and `enr_threshold` to 1, making AEC3 switch to its gentler `nearend_tuning` suppression curve
sooner; measured improvement is -10.6 dB → -6.85 dB, still short of the 3 dB target. Pushing the
`nearend_tuning` masking thresholds further toward transparent (tried: both `mask_lf`/`mask_hf`
raised to 2.0) made it *worse* (-12.7 dB) rather than better, so that attempt was reverted —
the masking-threshold semantics evidently don't behave as "higher = more transparent" the way
the field names suggest, and reverse-engineering them further was out of scope for this pass.
This is flagged as an open item in the task report; the ERLE (far-end-only and nonlinear)
targets are both met.
