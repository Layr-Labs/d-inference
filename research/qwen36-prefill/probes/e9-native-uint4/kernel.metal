#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

using namespace metal;
using namespace mpp::tensor_ops;

#if !__HAVE_INT4B_FORMAT_TYPE__
#error "E9 requires Metal uint4b_format support (macOS 26.4 SDK or newer)"
#endif

// One fixed group-64 tile from the Qwen gate_up cell:
//   full cell: M=64, K=2048, N=1024
//   this tile: M=16, K=64, N=32
//
// Activations are row-major [M,K]. Packed codes are logically [K,N], with
// adjacent N elements packed low-nibble first by the host. Scale and bias are
// BF16 [N] values for this one K group. No MLX or serving symbol references
// this kernel.
constexpr int tileM = 16;
constexpr int tileN = 32;
constexpr int groupK = 64;

using XExtents = metal::extents<int, groupK, tileM>;
using QExtents = metal::extents<int, tileN, groupK>;
using CExtents = metal::extents<int, tileN, tileM>;

kernel void e9_native_uint4_affine_group64(
    const device bfloat* activations [[buffer(0)]],
    const device uint4b_format* packed_codes [[buffer(1)]],
    const device bfloat* scales [[buffer(2)]],
    const device bfloat* biases [[buffer(3)]],
    device float* output [[buffer(4)]],
    ushort lane [[thread_index_in_simdgroup]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      tileM,
      tileN,
      groupK,
      false,
      false,
      false, // relaxed_precision=false is the E9 contract.
      matmul2d_descriptor::mode::multiply);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto x = metal::tensor(
      activations, XExtents{}, metal::array<int, 2>{1, groupK});
  auto q = metal::tensor(
      packed_codes, QExtents{}, metal::array<int, 2>{1, tileN});
  auto c = metal::tensor(
      output, CExtents{}, metal::array<int, 2>{1, tileN});
  auto q_dot =
      operation.get_destination_cooperative_tensor<decltype(x), decltype(q), float>();

  threadgroup float row_sums[tileM];
  if (lane < tileM) {
    float sum = 0.0f;
#pragma unroll full
    for (ushort k = 0; k < groupK; ++k) {
      sum += float(activations[int(lane) * groupK + int(k)]);
    }
    row_sums[lane] = sum;
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);

  operation.run(x, q, q_dot);

#pragma unroll full
  for (ushort i = 0; i < q_dot.get_capacity(); ++i) {
    if (q_dot.is_valid_element(i)) {
      const auto coordinate = q_dot.get_multidimensional_index(i);
      const int column = coordinate[0];
      const int row = coordinate[1];
      q_dot[i] =
          float(scales[column]) * q_dot.get(i) +
          float(biases[column]) * row_sums[row];
    }
  }
  q_dot.store(c);
}
