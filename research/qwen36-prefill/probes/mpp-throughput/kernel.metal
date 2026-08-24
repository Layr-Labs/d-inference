#include <metal_simdgroup_matrix>
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

using namespace metal;
using namespace mpp::tensor_ops;

struct DenseShape {
  uint m;
  uint k;
  uint n;
};

#if defined(COMPILE_MPP_CANDIDATE)

#if !defined(MPP_TILE_M) || !defined(MPP_TILE_N) || !defined(MPP_TILE_K) || \
    !defined(MPP_SCOPE_SIMDGROUPS) || !defined(MPP_FUNCTION)
#error "MPP candidate compile requires tile, scope, and function macros"
#endif

#if MPP_SCOPE_SIMDGROUPS == 1
using MPPScope = metal::execution_simdgroup;
constant constexpr uint mppOutputTilesPerThreadgroup = 4;
#elif MPP_SCOPE_SIMDGROUPS == 2
using MPPScope = metal::execution_simdgroups<2>;
constant constexpr uint mppOutputTilesPerThreadgroup = 1;
#elif MPP_SCOPE_SIMDGROUPS == 4
using MPPScope = metal::execution_simdgroups<4>;
constant constexpr uint mppOutputTilesPerThreadgroup = 1;
#else
#error "MPP_SCOPE_SIMDGROUPS must be 1, 2, or 4"
#endif

constant constexpr uint mppTileM = MPP_TILE_M;
constant constexpr uint mppTileN = MPP_TILE_N;
constant constexpr uint mppTileK = MPP_TILE_K;

using MPPLeftExtents = metal::extents<int, MPP_TILE_K, MPP_TILE_M>;
using MPPRightExtents = metal::extents<int, MPP_TILE_N, MPP_TILE_K>;
using MPPDestinationExtents = metal::extents<int, MPP_TILE_N, MPP_TILE_M>;

// Every matrix entry in the compile matrix instantiates this strict
// BF16xBF16->FP32 operation independently. A single-SIMD-group operation packs
// four independent output tiles into one threadgroup. Multi-SIMD-group scopes
// use exactly the configured 2 or 4 groups cooperatively for one output tile,
// as required by the Metal 4 execution-scope contract.
kernel void MPP_FUNCTION(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant DenseShape& shape [[buffer(3)]],
    ushort simdgroup_index [[simdgroup_index_in_threadgroup]],
    uint3 threadgroup_position [[threadgroup_position_in_grid]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      int(mppTileM),
      int(mppTileN),
      int(mppTileK),
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, MPPScope> operation;

  const uint n_tiles = shape.n / mppTileN;
  const uint tile_index = MPP_SCOPE_SIMDGROUPS == 1
      ? threadgroup_position.x * mppOutputTilesPerThreadgroup +
          uint(simdgroup_index)
      : threadgroup_position.x;
  const uint m_origin = (tile_index / n_tiles) * mppTileM;
  const uint n_origin = (tile_index % n_tiles) * mppTileN;

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
    if (cooperative_c.get_mask(i)) {
      cooperative_c.set(i, 0.0f);
    }
  }

#pragma clang loop unroll(disable)
  for (uint k_origin = 0; k_origin < shape.k; k_origin += mppTileK) {
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

#endif

#if defined(COMPILE_STEEL)

// The Steel control keeps the incumbent 16x32 output tile and four independent
// SIMD groups per threadgroup. It is compiled into its own metallib so one
// rejected MPP descriptor cannot suppress the reference pipeline.
constant constexpr uint steelTileM = 16;
constant constexpr uint steelTileN = 32;
constant constexpr uint steelChunkK = 8;
constant constexpr uint steelSIMDGroupsPerThreadgroup = 4;
using SteelFragment = metal::simdgroup_matrix<float, 8, 8>;

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
  const uint n_tiles = shape.n / steelTileN;
  const uint tile_index =
      threadgroup_position.x * steelSIMDGroupsPerThreadgroup +
      uint(simdgroup_index);
  const uint m_origin = (tile_index / n_tiles) * steelTileM;
  const uint n_origin = (tile_index % n_tiles) * steelTileN;

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

#endif
