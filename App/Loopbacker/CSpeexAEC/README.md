# CSpeexAEC

Vendored subset of [xiph/speexdsp](https://github.com/xiph/speexdsp), pinned at commit
`7a158783df74efe7c2d1c6ee8363c1e695c71226` (2025-07-05). License: BSD-3-Clause, see
`../Resources/SpeexDSP-LICENSE.txt` (copied verbatim from upstream `COPYING`).

## Why SpeexDSP instead of WebRTC AEC3

The task called for vendoring WebRTC's AEC3 (`webrtc-audio-processing`, the freedesktop fork)
as the echo canceller. A real attempt was made: the upstream repo was cloned and its
`webrtc/modules/audio_processing/aec3/` directory audited file-by-file for its actual
dependency closure. AEC3 itself is self-contained C++ (~125 files), but its *build* pulls in
substantial infrastructure that doesn't shrink under manual pruning:

- `rtc_base/` (checks, logging, field trials, race checker, swap queue) and `system_wrappers/`
  (cpu_features, field_trial, metrics) are WebRTC's own platform-abstraction layer — not
  optional, every AEC3 source file includes several of them.
- `common_audio/signal_processing/` (51 files) and `common_audio/third_party/ooura/` (two FFT
  implementations) are needed for the fixed/float signal processing primitives AEC3 calls.
- `api/audio/echo_canceller3_config.{h,cc}` and `api/array_view.h` pull in one `absl/strings`
  header, meaning a full (or WrapDB-trimmed) abseil-cpp becomes a transitive SwiftPM C++
  dependency — a multi-hundred-file library with its own build-system assumptions (Bazel/GN
  config macros, `ABSL_ATTRIBUTE_*` compiler-support detection) that don't map cleanly onto
  SwiftPM's `cSettings`/`cxxSettings` without reproducing a meson/GN-equivalent configure step.
- None of this is shipped as prebuilt artifacts for macOS; Homebrew has no
  `webrtc-audio-processing` formula, so there is no way to link a system copy either.

Reconstructing GN's dependency resolution and abseil's configure-time macros by hand inside
SwiftPM's declarative target model, for a single algorithm, was judged infeasible within the
scope of this task — the C++ target would effectively become "vendor a slice of abseil too,"
which is a different and much larger vendoring job. SpeexDSP's MDF echo canceller, by contrast,
is plain C89 with a ~20-file dependency closure (see below) and no external library
dependencies beyond libc, so it was used instead per the task's documented fallback.

## Files
- `mdf.c` — the MDF (Multi-Delay block Frequency-domain) adaptive echo canceller itself
  (`speex_echo_state_init`, `_cancellation`, `_reset`, `_destroy`, `_ctl`), upstream
  `libspeexdsp/mdf.c` unmodified.
- `fftwrap.c/.h`, `kiss_fft.c/.h`, `kiss_fftr.c/.h`, `_kiss_fft_guts.h` — SpeexDSP's FFT
  abstraction layer, configured (`USE_KISS_FFT`) to use the bundled KissFFT backend rather than
  MKL/IPP/FFTW3/`smallft`, all of which are `#ifdef`-excluded by not defining their macros.
- `arch.h`, `os_support.h`, `pseudofloat.h`, `math_approx.h` — upstream support headers MDF and
  the FFT layer both need (architecture macros, `speex_alloc`/`speex_warning` wrappers, the
  float/fixed-point-agnostic "pseudofloat" type, polynomial math approximations).
- `include/speex/speex_echo.h`, `include/speex/speexdsp_types.h` — upstream public API and
  integer-type typedefs (the `#else` branch for non-Windows/non-embedded platforms resolves to
  plain `<sys/types.h>` typedefs on Apple platforms, so the autoconf-generated
  `speexdsp_config_types.h` is not needed).

Built with `FLOATING_POINT` (not `FIXED_POINT`) and `USE_KISS_FFT`; `EXPORT` is defined empty
since this links as a single SwiftPM target, not a shared library with explicit visibility
annotations.

## Omitted
Everything else in `libspeexdsp/`: the full resampler (`resample.c`), noise
preprocessor/AGC/VAD (`preprocess.c` — `NoiseSuppressor` already covers this via RNNoise),
jitter buffer (`jitter.c`), filterbank/Bark-scale utilities, the Ogg/Vorbis-derived
`smallft.c`/`vorbis_psy.h` FFT alternative (unused, `USE_KISS_FFT` selected instead), fixed-point
headers (`fixed_*.h`), MIPS/ARM/Blackfin DSP intrinsics headers, build system files
(`Makefile.am`, `configure.ac`), tests (`testecho.c`, etc.), and documentation.

## Allocation / real-time safety
`speex_echo_state_init`/`_init_mc` are the only functions in `mdf.c` that call `speex_alloc`
(every `st-> = speex_alloc(...)` line is inside `speex_echo_state_init`). `EchoCanceller` calls
this once at construction (`EchoCanceller.make`), never from the IO thread.
`speex_echo_cancellation`, `speex_echo_state_reset`, and `speex_echo_ctl`'s `GET_*` paths touch
only pre-allocated state and do not call `speex_alloc`/`malloc`/`calloc`/`realloc` — verified by
reading every code path reachable from `speex_echo_cancellation` in `mdf.c`, plus the KissFFT
FFT execute path (`kiss_fftr2`/`kiss_fftri2`), which only touches the config buffer built once
at `spx_fft_init` time (also called only from `speex_echo_state_init`). `EchoCanceller.process`
additionally never calls `speex_echo_state_init`/`_destroy` outside of `make`/`deinit`.
