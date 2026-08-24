#include <metal_simdgroup_matrix>
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

using namespace metal;
using namespace mpp::tensor_ops;

// Both kernels assign one 16x32 output tile to one SIMD group. Four
// independent SIMD groups share a threadgroup; no threadgroup memory or
// cross-SIMD communication is used.
constant constexpr uint tileM = 16;
constant constexpr uint tileN = 32;
constant constexpr uint mppChunkK = 16;
constant constexpr uint steelChunkK = 8;
constant constexpr uint simdgroupsPerThreadgroup = 4;

struct DenseShape {
  uint m;
  uint k;
  uint n;
};

using MPPLeftExtents = metal::extents<int, mppChunkK, tileM>;
using MPPRightExtents = metal::extents<int, tileN, mppChunkK>;
using MPPDestinationExtents = metal::extents<int, tileN, tileM>;
using SteelFragment = metal::simdgroup_matrix<float, 8, 8>;

METAL_FUNC uint output_tile_index(
    uint threadgroup_index,
    ushort simdgroup_index) {
  return threadgroup_index * simdgroupsPerThreadgroup +
      uint(simdgroup_index);
}

// Metal 4 MPP Candidate A. The descriptor K is statically 16. Each loop
// iteration uses supported cooperative-tensor load operations for BF16 A/B,
// while one FP32 cooperative destination remains live for the entire logical
// K reduction. Only the final FP32 tile is stored.
kernel void mpp_bf16_fp32_static_k16(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant DenseShape& shape [[buffer(3)]],
    ushort simdgroup_index [[simdgroup_index_in_threadgroup]],
    uint3 threadgroup_position [[threadgroup_position_in_grid]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      int(tileM),
      int(tileN),
      int(mppChunkK),
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  const uint n_tiles = shape.n / tileN;
  const uint tile_index =
      output_tile_index(threadgroup_position.x, simdgroup_index);
  const uint m_origin = (tile_index / n_tiles) * tileM;
  const uint n_origin = (tile_index % n_tiles) * tileN;

  auto cooperative_a =
      operation.get_left_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_b =
      operation.get_right_input_cooperative_tensor<bfloat, bfloat, float>();
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
  for (uint k_origin = 0; k_origin < shape.k; k_origin += mppChunkK) {
    auto a_tile = metal::tensor(
        a + m_origin * shape.k + k_origin,
        MPPLeftExtents{},
        metal::array<int, 2>{1, int(shape.k)});
    auto b_tile = metal::tensor(
        b + k_origin * shape.n + n_origin,
        MPPRightExtents{},
        metal::array<int, 2>{1, int(shape.n)});
    cooperative_a.load(a_tile);
    cooperative_b.load(b_tile);
    operation.run(cooperative_a, cooperative_b, cooperative_c);
  }

  auto c_tile = metal::tensor(
      output + m_origin * shape.n + n_origin,
      MPPDestinationExtents{},
      metal::array<int, 2>{1, int(shape.n)});
  cooperative_c.store(c_tile);
}

// Steel control. This is the same 8x8 simdgroup matrix primitive and FP32
// fragment contract used by BaseMMAFrag<float>: BF16 values are promoted while
// loading each fragment, and one FP32 accumulator per 8x8 output fragment is
// retained across all K/8 operations. Its input buffers and FP32 output
// boundary are identical to the MPP arm.
kernel void steel_simdgroup_fp32_reference(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant DenseShape& shape [[buffer(3)]],
    ushort lane [[thread_index_in_simdgroup]],
    ushort simdgroup_index [[simdgroup_index_in_threadgroup]],
    uint3 threadgroup_position [[threadgroup_position_in_grid]]) {
  const uint n_tiles = shape.n / tileN;
  const uint tile_index =
      output_tile_index(threadgroup_position.x, simdgroup_index);
  const uint m_origin = (tile_index / n_tiles) * tileM;
  const uint n_origin = (tile_index % n_tiles) * tileN;

  const ushort qid = lane >> 2;
  const uint fragment_row = uint((qid & 4) + ((lane >> 1) & 3));
  const uint fragment_column = uint(((qid & 2) | (lane & 1)) * 2);

  SteelFragment c00 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  SteelFragment c01 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  SteelFragment c02 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  SteelFragment c03 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  SteelFragment c10 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  SteelFragment c11 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  SteelFragment c12 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  SteelFragment c13 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);

#pragma clang loop unroll(disable)
  for (uint k_origin = 0; k_origin < shape.k; k_origin += steelChunkK) {
    SteelFragment a0;
    SteelFragment a1;
    SteelFragment b0;
    SteelFragment b1;
    SteelFragment b2;
    SteelFragment b3;

    a0.thread_elements()[0] = float(
        a[(m_origin + fragment_row) * shape.k +
          k_origin + fragment_column]);
    a0.thread_elements()[1] = float(
        a[(m_origin + fragment_row) * shape.k +
          k_origin + fragment_column + 1]);
    a1.thread_elements()[0] = float(
        a[(m_origin + 8 + fragment_row) * shape.k +
          k_origin + fragment_column]);
    a1.thread_elements()[1] = float(
        a[(m_origin + 8 + fragment_row) * shape.k +
          k_origin + fragment_column + 1]);

    b0.thread_elements()[0] = float(
        b[(k_origin + fragment_row) * shape.n +
          n_origin + fragment_column]);
    b0.thread_elements()[1] = float(
        b[(k_origin + fragment_row) * shape.n +
          n_origin + fragment_column + 1]);
    b1.thread_elements()[0] = float(
        b[(k_origin + fragment_row) * shape.n +
          n_origin + 8 + fragment_column]);
    b1.thread_elements()[1] = float(
        b[(k_origin + fragment_row) * shape.n +
          n_origin + 8 + fragment_column + 1]);
    b2.thread_elements()[0] = float(
        b[(k_origin + fragment_row) * shape.n +
          n_origin + 16 + fragment_column]);
    b2.thread_elements()[1] = float(
        b[(k_origin + fragment_row) * shape.n +
          n_origin + 16 + fragment_column + 1]);
    b3.thread_elements()[0] = float(
        b[(k_origin + fragment_row) * shape.n +
          n_origin + 24 + fragment_column]);
    b3.thread_elements()[1] = float(
        b[(k_origin + fragment_row) * shape.n +
          n_origin + 24 + fragment_column + 1]);

    metal::simdgroup_multiply_accumulate(c00, a0, b0, c00);
    metal::simdgroup_multiply_accumulate(c01, a0, b1, c01);
    metal::simdgroup_multiply_accumulate(c02, a0, b2, c02);
    metal::simdgroup_multiply_accumulate(c03, a0, b3, c03);
    metal::simdgroup_multiply_accumulate(c10, a1, b0, c10);
    metal::simdgroup_multiply_accumulate(c11, a1, b1, c11);
    metal::simdgroup_multiply_accumulate(c12, a1, b2, c12);
    metal::simdgroup_multiply_accumulate(c13, a1, b3, c13);
  }

#define STORE_STEEL_FRAGMENT(FRAGMENT, ROW_OFFSET, COLUMN_OFFSET)            \
  output[(m_origin + (ROW_OFFSET) + fragment_row) * shape.n +                \
         n_origin + (COLUMN_OFFSET) + fragment_column] =                     \
      (FRAGMENT).thread_elements()[0];                                       \
  output[(m_origin + (ROW_OFFSET) + fragment_row) * shape.n +                \
         n_origin + (COLUMN_OFFSET) + fragment_column + 1] =                 \
      (FRAGMENT).thread_elements()[1]

  STORE_STEEL_FRAGMENT(c00, 0, 0);
  STORE_STEEL_FRAGMENT(c01, 0, 8);
  STORE_STEEL_FRAGMENT(c02, 0, 16);
  STORE_STEEL_FRAGMENT(c03, 0, 24);
  STORE_STEEL_FRAGMENT(c10, 8, 0);
  STORE_STEEL_FRAGMENT(c11, 8, 8);
  STORE_STEEL_FRAGMENT(c12, 8, 16);
  STORE_STEEL_FRAGMENT(c13, 8, 24);

#undef STORE_STEEL_FRAGMENT
}
