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

## x86_64 support

The app ships for Apple silicon only, but GitHub's CodeQL Swift analysis builds the whole
package as x86_64 (see `../AGENTS.md`), so this target has to compile — not run correctly,
just compile — under `swift build --arch x86_64` too.

`rtc_base/system/arch.h` already derives `WEBRTC_ARCH_X86_FAMILY`/`WEBRTC_ARCH_ARM_FAMILY` from
compiler macros (`__x86_64__`/`__aarch64__`), so Package.swift does not hard-code an arch
define (it used to hard-code `WEBRTC_ARCH_ARM64`, which was simply wrong on an x86_64 build —
harmless in practice since nothing here keys behavior on that macro alone, but misleading and
the thing that made `generate.py` only ever vendor an arm64 closure). The real gap was that the
single arm64 meson build this was vendored from never compiles the x86 SIMD translation units
(SSE2/AVX2 `FIRFilter`, `SincResampler`, the Ooura FFT, and several AEC3 kernels) — they are
arch-conditional in upstream's own `meson.build`, so an arm64-only vendoring pass can't produce
them no matter how it walks the dependency graph.

`generate.py` now also accepts `--x86-64-build-dir <dir>` (point it at an x86_64 meson
cross-build; see the usage comment at the top of the script for the cross file) and unions in
whatever extra translation units that closure has over the primary (arm64) one — currently 14
files, all under `common_audio/` and `modules/audio_processing/{aec3,agc2/rnn_vad}/`.

Those 14 files are patched on the way in, because SwiftPM compiles one source list per target
regardless of `--arch` (no per-file or per-arch source list exists), and they unconditionally
`#include <xmmintrin.h>`/`<immintrin.h>`, which themselves `#error` outside
`__i386__`/`__x86_64__` — so left unpatched they would break `swift build` (arm64, what ships):
- Every x86-only `.cc`/`.c` is wrapped in `#if defined(__x86_64__)` / `#endif`, so it compiles
  to an empty translation unit on arm64 (confirmed: stripped arm64 release binary is
  byte-for-byte identical before/after this vendoring — see `../AGENTS.md`'s "x86_64" build
  line and `generate.py`'s module docstring for the measurement).
- The subset whose original meson compile command used `-mavx2`/`-mfma` (ground truth from
  `compdb`, not guessed from the filename — `adaptive_fir_filter_avx2.cc`,
  `adaptive_fir_filter_erl_avx2.cc`, `fft_data_avx2.cc`, `fir_filter_avx2.cc`,
  `matched_filter_avx2.cc`, `sinc_resampler_avx2.cc`, and both `vector_math_avx2.cc`s) is
  additionally wrapped in
  `#pragma clang attribute push(__attribute__((target("avx2,fma"))), apply_to = function)` /
  `pop`, since SwiftPM also can't pass `-mavx2 -mfma` to only those files — raising the whole
  target's baseline ISA instead would make the output binary require a newer-than-SSE2 CPU and
  would break compiling the same target for arm64. The plain `*_sse.cc`/`*_sse2.cc` files need
  no such attribute: SSE2 is baseline for x86-64, no special compile flag required.
- The 3 new headers (`fir_filter_avx2.h`, `fir_filter_sse.h`,
  `ooura_fft_tables_neon_sse2.h`) are copied unpatched — none of them use raw intrinsics outside
  an existing `#if defined(WEBRTC_ARCH_X86_FAMILY)` guard (itself already arch-safe via
  `arch.h`), so they compile cleanly on both arches as-is.

`GetCPUInfo(kAVX2)`'s runtime CPUID check (`system_wrappers/source/cpu_features.cc`) is gated on
`WEBRTC_ENABLE_AVX2`, which Package.swift now defines (an x86_64 meson build adds it
automatically; an arm64 one doesn't) — harmless on arm64, since it only guards code already
behind `#if defined(WEBRTC_ARCH_X86_FAMILY)`.

No equivalent patching is needed for `../CYSFX` or `../CAirwindows`: CYSFX's EEL2 JIT already
selects `glue_aarch64.h` vs `glue_x86_64_sse.h` via the same compiler macros, and its vendored
x86-64 JIT trampoline (`../CYSFX/ysfx-sources/eel2-gas/asm-nseel-x64-sse.S`) ships
pre-wrapped in `#if defined(__x86_64__)` upstream; CAirwindows has no architecture-specific code
at all. Both compile under `swift build --arch x86_64` unmodified.

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
`enr_threshold = .25`, `hold_duration = 50`, `trigger_threshold = 12`) are tuned for WebRTC's
own call scenarios. In this app's synthetic double-talk test (far-end echo + near-end speech
overlapping after the echo path has converged), the harder question isn't "does it suppress
the echo" (it does -- ERLE stays above 31 dB regardless of tuning) but "does it over-suppress
the near-end talker while doing so."

The earlier report (first AEC3 landing) measured this only at an unrealistic ~0 dB echo:near
ratio (echo as loud as the near-end talker) and found stock AEC3 moved the near-end level
-10.6 dB, a first tuning pass improved that to -6.85 dB, and a second pass pushing
`nearend_tuning`'s masking thresholds toward "transparent" made it *worse* (-12.7 dB). Real
desk speakers put the echo well below the near-end talker's own mic level -- roughly -10 to
-20 dB, not 0 dB -- so a proper sweep was run across echo:near-end ratios of 0/-6/-12/-18 dB,
comparing AEC3's stock config against the two tuning candidates below:

- **tuned (shipped)**: `snr_threshold = 5`, `enr_threshold = 1`, `enr_exit_threshold = 2`,
  `hold_duration = 10`, `trigger_threshold = 1` -- lower thresholds plus faster entry/re-entry
  into the gentler `nearend_tuning` suppression curve.
- **tuned (slow-entry, rejected)**: same `snr_threshold`/`enr_threshold` but stock
  `enr_exit_threshold`/`hold_duration = 25`/`trigger_threshold = 3` -- the first tuning pass's
  values, included here as a baseline showing what "slower to notice double talk" costs.

Near-end level change during double talk (dB, negative = near-end talker suppressed; target:
within 3 dB), measured over the last 2 s of an 8 s scenario (4 s far-end-only convergence +
4 s double talk, 80 ms bulk delay, 30 ppm drift):

| echo:near ratio | stock AEC3 | tuned, slow-entry | **tuned (shipped)** |
|---|---|---|---|
| 0 dB (harsher than real speakers; not a target) | -12.95 dB | -8.01 dB | -8.10 dB |
| -6 dB | -4.19 dB | -2.99 dB | **-2.92 dB** |
| -12 dB (acceptance target, real desk range) | -2.23 dB | -1.61 dB | **-1.58 dB** |
| -18 dB (real desk range) | -2.66 dB | -2.66 dB | -2.67 dB |

Far-end-only ERLE for the same three configs (9 s scenario, 90 ms bulk delay, last 2 s,
required ≥ 25 dB for this comparison -- the shipped acceptance bar in `EchoCancellerTests` is
20 dB linear / 10 dB nonlinear and is unaffected by this tuning, since `dominant_nearend_
detection` only changes behavior when near-end speech is present):

| | stock AEC3 | tuned, slow-entry | **tuned (shipped)** |
|---|---|---|---|
| linear | 32.01 dB | 31.48 dB | 31.57 dB |
| nonlinear (tanh soft-clip) | 31.85 dB | 31.17 dB | 31.32 dB |

The shipped config wins (or ties within measurement noise) at both -6 dB and -12 dB -- the
ratios that matter for a real desk -- while giving up under 0.5 dB of ERLE versus stock. At
-18 dB all three configs converge to the same ~-2.66 to -2.67 dB regardless of tuning: at that
ratio the echo is quiet enough that `dominant_nearend_detection`'s thresholds rarely trigger at
all, and the small residual suppression comes from `normal_tuning`/the high-pass filter instead
-- consistent with `dominant_nearend_detection` only mattering once the echo is loud enough to
actually contend with the near-end talker.

`EchoCancellerTests.doubleTalk` asserts the -12 dB case stays within the 3 dB target (both
tuned configs pass comfortably; stock AEC3 also happens to pass -12 dB, just with less margin).
`EchoCancellerTests.doubleTalkEqualLevelRegressionGuard` is a non-target regression guard at
the harsher 0 dB ratio, asserting no more than 10 dB (the shipped config's measured -8.10 dB,
rounded up to 9, plus 1 dB margin) -- not a pass/fail acceptance bar, since no real speaker
produces a 0 dB echo:near ratio.

Knobs tried and rejected during the sweep (kept here so the next pass doesn't repeat them):
pushing `nearend_tuning`'s `MaskingThresholds` toward "transparent" (both `mask_lf`/`mask_hf`
raised to 2.0) made preservation *worse* (-12.7 dB at 0 dB ratio) rather than better -- the
masking-threshold semantics evidently don't behave as "higher = more transparent" the way the
field names suggest, and reverse-engineering `suppression_gain.cc`'s exact gain computation
was out of scope for this pass.
