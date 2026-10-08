import MLX

/// W4/W8 arithmetic adapted from Apple qmv_impl, qmv_fast_impl, load_vector
/// and qdot. MIT notice is retained in UPSTREAM-LICENSE.txt. Exact compiled
/// bytes remain a qualification condition, not a consequence asserted here.
enum GemmaSmallQMVArithmetic {
    static let body = #"""
        // VPT and the 32-lane partition match the actual M1 qmv/qmv_fast.
        // Every supported K is group64 aligned, hence no partial live lane.
        float result[3][4] = {{0,0,0,0},{0,0,0,0},{0,0,0,0}};
        for (uint base = 0; base < K; base += VPT * 32) {
            const uint column = base + lane * VPT;
            if (column < K) {
                float values[3][VPT];
                float sums[3] = {0,0,0};
                for (uint m = 0; m < count; ++m) {
                    const uint input_row = TokenRows ? members[m] / 8 : members[m];
                    const device T* v = x + input_row * K + column;
                    if constexpr (Bits == 4) {
                        for (uint q = 0; q < VPT; q += 4) {
                            sums[m] += float(v[q]) + float(v[q+1]) + float(v[q+2]) + float(v[q+3]);
                            values[m][q] = v[q];
                            values[m][q+1] = v[q+1] / 16.0f;
                            values[m][q+2] = v[q+2] / 256.0f;
                            values[m][q+3] = v[q+3] / 4096.0f;
                        }
                    } else {
                        for (uint q = 0; q < VPT; ++q) {
                            sums[m] += v[q]; values[m][q] = v[q];
                        }
                    }
                }
                for (uint row = 0; row < 4; ++row) {
                    const uint plane_row = expert * N + out_row + row;
                    constexpr uint packs = VPT * Bits / 32;
                    uint packed[packs];
                    for (uint q = 0; q < packs; ++q) {
                        packed[q] = w[plane_row * (K * Bits / 32) + column * Bits / 32 + q];
                    }
                    const float scale = scales[plane_row * (K/64) + column/64];
                    const float bias = biases[plane_row * (K/64) + column/64];
                    for (uint m = 0; m < count; ++m) {
                        float accum = 0;
                        if constexpr (Bits == 4) {
                            for (uint q = 0; q < VPT / 4; ++q) {
                                const uint word = (packed[q/2] >> ((q%2)*16)) & 0xffffu;
                                accum += (values[m][4*q] * (word & 0x000fu)
                                    + values[m][4*q+1] * (word & 0x00f0u)
                                    + values[m][4*q+2] * (word & 0x0f00u)
                                    + values[m][4*q+3] * (word & 0xf000u));
                            }
                        } else {
                            for (uint q = 0; q < VPT; ++q) {
                                accum += values[m][q] * ((packed[q/4] >> ((q%4)*8)) & 0xffu);
                            }
                        }
                        result[m][row] += scale * accum + sums[m] * bias;
                    }
                }
            }
        }
        for (uint m = 0; m < count; ++m) {
            for (uint row = 0; row < 4; ++row) {
                const float reduced = simd_sum(result[m][row]);
                if (lane == 0) { out[members[m] * N + out_row + row] = T(reduced); }
            }
        }
        """#
}
