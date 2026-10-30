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
#include <stddef.h>
#include <stdint.h>
#include <xmmintrin.h>

#include "common_audio/resampler/sinc_resampler.h"

#pragma clang attribute push(__attribute__((target("avx2,fma"))), apply_to = function)

namespace webrtc {

float SincResampler::Convolve_AVX2(const float* input_ptr,
                                   const float* k1,
                                   const float* k2,
                                   double kernel_interpolation_factor) {
  __m256 m_input;
  __m256 m_sums1 = _mm256_setzero_ps();
  __m256 m_sums2 = _mm256_setzero_ps();

  // Based on `input_ptr` alignment, we need to use loadu or load.  Unrolling
  // these loops has not been tested or benchmarked.
  bool aligned_input = (reinterpret_cast<uintptr_t>(input_ptr) & 0x1F) == 0;
  if (!aligned_input) {
    for (size_t i = 0; i < kKernelSize; i += 8) {
      m_input = _mm256_loadu_ps(input_ptr + i);
      m_sums1 = _mm256_fmadd_ps(m_input, _mm256_load_ps(k1 + i), m_sums1);
      m_sums2 = _mm256_fmadd_ps(m_input, _mm256_load_ps(k2 + i), m_sums2);
    }
  } else {
    for (size_t i = 0; i < kKernelSize; i += 8) {
      m_input = _mm256_load_ps(input_ptr + i);
      m_sums1 = _mm256_fmadd_ps(m_input, _mm256_load_ps(k1 + i), m_sums1);
      m_sums2 = _mm256_fmadd_ps(m_input, _mm256_load_ps(k2 + i), m_sums2);
    }
  }

  // Linearly interpolate the two "convolutions".
  __m128 m128_sums1 = _mm_add_ps(_mm256_extractf128_ps(m_sums1, 0),
                                 _mm256_extractf128_ps(m_sums1, 1));
  __m128 m128_sums2 = _mm_add_ps(_mm256_extractf128_ps(m_sums2, 0),
                                 _mm256_extractf128_ps(m_sums2, 1));
  m128_sums1 = _mm_mul_ps(
      m128_sums1,
      _mm_set_ps1(static_cast<float>(1.0 - kernel_interpolation_factor)));
  m128_sums2 = _mm_mul_ps(
      m128_sums2, _mm_set_ps1(static_cast<float>(kernel_interpolation_factor)));
  m128_sums1 = _mm_add_ps(m128_sums1, m128_sums2);

  // Sum components together.
  float result;
  m128_sums2 = _mm_add_ps(_mm_movehl_ps(m128_sums1, m128_sums1), m128_sums1);
  _mm_store_ss(&result, _mm_add_ss(m128_sums2,
                                   _mm_shuffle_ps(m128_sums2, m128_sums2, 1)));

  return result;
}

}  // namespace webrtc

#pragma clang attribute pop
#endif  // defined(__x86_64__)
