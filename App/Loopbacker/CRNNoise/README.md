# CRNNoise

Vendored subset of [xiph/rnnoise](https://github.com/xiph/rnnoise), pinned at release
**v0.2** (source tag `v0.2`; model weights tag `0b50c45`, downloaded separately per
upstream's own `download_model.sh` from `https://media.xiph.org/rnnoise/models/rnnoise_data-0b50c45.tar.gz`,
since v0.2's source tarball ships `model_version` + a download script rather than the
baked-in data file). License: BSD-3-Clause, see `../Resources/RNNoise-LICENSE.txt`
(copied verbatim from upstream `COPYING`).

Only the files needed for `rnnoise_create` / `rnnoise_init` / `rnnoise_process_frame` /
`rnnoise_get_size` / `rnnoise_get_frame_size` / `rnnoise_destroy` are included, built for
arm64 only (no x86 SSE/AVX2 runtime dispatch; `RNN_ENABLE_X86_RTCD` and `ENABLE_OSCE` are
never defined, so `nnet.h`'s `compute_linear`/`compute_activation`/`compute_conv2d` macros
resolve directly to the portable `_c` implementations and NEON vector code in
`vec_neon.h`, compiled unconditionally for AArch64).

Default model (`rnnoise_data.c`/`.h`, the `rnnoise8Za_25.pth` weights), not the "little"
variant: ~29 MB of generated C source, ~4.5 MB of float weight data once compiled into the
binary (counted per-array from the `WEIGHT_TYPE_*` declarations). The "little" model is
roughly half that (~2.3 MB compiled) — default was kept since the extra footprint is
small in absolute terms and the default model is the stronger denoiser.

## Files
- `include/rnnoise.h` — public API (upstream `include/rnnoise.h`).
- `denoise.c/.h`, `pitch.c/.h`, `celt_lpc.c/.h`, `kiss_fft.c/.h`, `_kiss_fft_guts.h`,
  `rnnoise_tables.c`, `rnn.c/.h`, `nnet.c/.h`, `nnet_default.c`, `nnet_arch.h`,
  `parse_lpcnet_weights.c`, `rnnoise_data.c/.h`, `common.h`, `arch.h`, `opus_types.h`,
  `cpu_support.h`, `vec.h`, `vec_neon.h`, `x86/x86_arch_macros.h` — upstream
  sources/headers, unmodified except one cast in `denoise.c`'s unused
  `rnnoise_model_from_file` (`model->blob_len = (int)ftell(f);`) to silence
  `-Wshorten-64-to-32`, the only warning the vendored sources produced under SwiftPM's
  default C warnings. (The x86 header is pulled in by a guarded `#include` in `vec.h`
  that never fires on arm64, but the file must exist for the preprocessor to find it if
  the guard were taken on another arch; kept for universal-capable builds.)
- `os_support.h` — **not** upstream. rnnoise normally pulls this from libopus; it's only
  used for the `OPUS_CLEAR` macro, so this is a 3-line local stand-in instead of vendoring
  all of libopus.

## Omitted
Everything else in the upstream tree: training code (`dump_features.c`,
`write_weights.c`, `TRAINING-README`, `scripts/`, Python training), the demo CLI
(`examples/rnnoise_demo.c`), autotools build files, the `rnnoise_data_little.c/.h`
alternate model, and the x86 SIMD sources (`x86/nnet_avx2.c`, `x86/nnet_sse4_1.c`,
`x86/x86cpu.c`, `x86/x86_dnn_map.c`, `x86/dnn_x86.h`, `x86/celt_lpc_sse.h`,
`x86/x86cpu.h`) since `RNN_ENABLE_X86_RTCD` is never defined.

## Allocation / real-time safety
`rnnoise_init(state, NULL)` (the path `RNNoiseKernel` uses, picking the statically-linked
default model) only `memset`s the state and copies pointers from the const weight arrays
into it — no heap allocation. `rnnoise_process_frame` likewise never calls
malloc/calloc/realloc/free (verified by reading every source file above and by an
interposed-malloc harness, see `RNNoiseKernel.swift`'s doc comment for the measured
result). `rnnoise_create`/`rnnoise_destroy`/`rnnoise_model_from_*` do allocate, but
`RNNoiseKernel` never calls them off the IO thread.
