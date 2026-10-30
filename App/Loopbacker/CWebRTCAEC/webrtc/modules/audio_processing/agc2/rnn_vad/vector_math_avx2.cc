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

#include "api/array_view.h"
#include "modules/audio_processing/agc2/rnn_vad/vector_math.h"
#include "rtc_base/checks.h"
#include "rtc_base/numerics/safe_conversions.h"

#pragma clang attribute push(__attribute__((target("avx2,fma"))), apply_to = function)

namespace webrtc {
namespace rnn_vad {

float VectorMath::DotProductAvx2(rtc::ArrayView<const float> x,
                                 rtc::ArrayView<const float> y) const {
  RTC_DCHECK(cpu_features_.avx2);
  RTC_DCHECK_EQ(x.size(), y.size());
  __m256 accumulator = _mm256_setzero_ps();
  constexpr int kBlockSizeLog2 = 3;
  constexpr int kBlockSize = 1 << kBlockSizeLog2;
  const int incomplete_block_index = (x.size() >> kBlockSizeLog2)
                                     << kBlockSizeLog2;
  for (int i = 0; i < incomplete_block_index; i += kBlockSize) {
    RTC_DCHECK_LE(i + kBlockSize, x.size());
    const __m256 x_i = _mm256_loadu_ps(&x[i]);
    const __m256 y_i = _mm256_loadu_ps(&y[i]);
    accumulator = _mm256_fmadd_ps(x_i, y_i, accumulator);
  }
  // Reduce `accumulator` by addition.
  __m128 high = _mm256_extractf128_ps(accumulator, 1);
  __m128 low = _mm256_extractf128_ps(accumulator, 0);
  low = _mm_add_ps(high, low);
  high = _mm_movehl_ps(high, low);
  low = _mm_add_ps(high, low);
  high = _mm_shuffle_ps(low, low, 1);
  low = _mm_add_ss(high, low);
  float dot_product = _mm_cvtss_f32(low);
  // Add the result for the last block if incomplete.
  for (int i = incomplete_block_index; i < rtc::dchecked_cast<int>(x.size());
       ++i) {
    dot_product += x[i] * y[i];
  }
  return dot_product;
}

}  // namespace rnn_vad
}  // namespace webrtc

#pragma clang attribute pop
#endif  // defined(__x86_64__)
