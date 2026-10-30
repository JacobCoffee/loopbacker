/*
 *  Copyright (c) 2020 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#if defined(__x86_64__)
// Vendoring patch (CWebRTCAEC, fx3/x86): this is an x86-only translation unit;
// SwiftPM compiles one source list per target regardless of --arch, so wrap the
// whole file instead of excluding it per arch. The AVX2/FMA intrinsics below need
// a target attribute since SwiftPM has no per-file compiler flags (upstream meson
// builds this translation unit with -mavx2 -mfma). See CWebRTCAEC/README.md.
#include <immintrin.h>

#include "modules/audio_processing/aec3/adaptive_fir_filter_erl.h"

#pragma clang attribute push(__attribute__((target("avx2,fma"))), apply_to = function)

namespace webrtc {

namespace aec3 {

// Computes and stores the echo return loss estimate of the filter, which is the
// sum of the partition frequency responses.
void ErlComputer_AVX2(
    const std::vector<std::array<float, kFftLengthBy2Plus1>>& H2,
    rtc::ArrayView<float> erl) {
  std::fill(erl.begin(), erl.end(), 0.f);
  for (auto& H2_j : H2) {
    for (size_t k = 0; k < kFftLengthBy2; k += 8) {
      const __m256 H2_j_k = _mm256_loadu_ps(&H2_j[k]);
      __m256 erl_k = _mm256_loadu_ps(&erl[k]);
      erl_k = _mm256_add_ps(erl_k, H2_j_k);
      _mm256_storeu_ps(&erl[k], erl_k);
    }
    erl[kFftLengthBy2] += H2_j[kFftLengthBy2];
  }
}

}  // namespace aec3
}  // namespace webrtc

#pragma clang attribute pop
#endif  // defined(__x86_64__)
