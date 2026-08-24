#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

using namespace metal;
using namespace mpp::tensor_ops;

struct ProblemShape {
  uint m;
  uint k;
  uint n;
};

constant constexpr uint tileM = 32;
constant constexpr uint tileN = 32;
constant constexpr uint tileK = 32;
constant constexpr uint simdgroupsPerThreadgroup = 4;

using LeftExtents = metal::extents<int, tileK, tileM>;
using RightExtents = metal::extents<int, tileN, tileK>;
using DestinationExtents = metal::extents<int, tileN, tileM>;

template <bool relaxed>
METAL_FUNC void run_mpp_f32(
    device float* a,
    device float* b,
    device float* output,
    constant ProblemShape& shape,
    ushort simdgroup_index,
    uint3 threadgroup_position) {
  // relaxed_precision is meaningful only for float operands: Metal 4 permits
  // truncating their mantissas before multiplication. Inputs in this probe are
  // BF16-representable values promoted to float, matching the values the
  // serving QMM currently presents to FP32 matrix fragments.
  constexpr auto descriptor = matmul2d_descriptor(
      int(tileM),
      int(tileN),
      int(tileK),
      false,
      false,
      relaxed,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  const uint n_tiles = shape.n / tileN;
  const uint tile_index =
      threadgroup_position.x * simdgroupsPerThreadgroup +
      uint(simdgroup_index);
  const uint m_origin = (tile_index / n_tiles) * tileM;
  const uint n_origin = (tile_index % n_tiles) * tileN;

  auto cooperative_a =
      operation.get_left_input_cooperative_tensor<float, float, float>();
  auto cooperative_b =
      operation.get_right_input_cooperative_tensor<float, float, float>();
  auto cooperative_c =
      operation.get_destination_cooperative_tensor<
          decltype(cooperative_a),
          decltype(cooperative_b),
          float>();

#pragma clang loop unroll(full)
  for (ushort i = 0; i < cooperative_c.get_capacity(); ++i) {
    cooperative_c.set(i, 0.0f);
  }

#pragma clang loop unroll(disable)
  for (uint k_origin = 0; k_origin < shape.k; k_origin += tileK) {
    auto a_tile = metal::tensor(
        a + m_origin * shape.k + k_origin,
        LeftExtents{},
        metal::array<int, 2>{1, int(shape.k)});
    auto b_tile = metal::tensor(
        b + k_origin * shape.n + n_origin,
        RightExtents{},
        metal::array<int, 2>{1, int(shape.n)});
    cooperative_a.load(a_tile);
    cooperative_b.load(b_tile);
    operation.run(cooperative_a, cooperative_b, cooperative_c);
  }

  auto c_tile = metal::tensor(
      output + m_origin * shape.n + n_origin,
      DestinationExtents{},
      metal::array<int, 2>{1, int(shape.n)});
  cooperative_c.store(c_tile);
}

kernel void mpp_f32_strict_m32_n32_k32(
    device float* a [[buffer(0)]],
    device float* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant ProblemShape& shape [[buffer(3)]],
    ushort simdgroup_index [[simdgroup_index_in_threadgroup]],
    uint3 threadgroup_position [[threadgroup_position_in_grid]]) {
  run_mpp_f32<false>(
      a, b, output, shape, simdgroup_index, threadgroup_position);
}

kernel void mpp_f32_relaxed_m32_n32_k32(
    device float* a [[buffer(0)]],
    device float* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant ProblemShape& shape [[buffer(3)]],
    ushort simdgroup_index [[simdgroup_index_in_threadgroup]],
    uint3 threadgroup_position [[threadgroup_position_in_grid]]) {
  run_mpp_f32<true>(
      a, b, output, shape, simdgroup_index, threadgroup_position);
}
