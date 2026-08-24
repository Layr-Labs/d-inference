#include <metal_simdgroup_matrix>
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

using namespace metal;
using namespace mpp::tensor_ops;

constant constexpr int tileM = 16;
constant constexpr int tileN = 32;
constant constexpr int steelK = 8;
constant constexpr int staticK = 16;

struct ProblemShape {
  uint m;
  uint n;
  uint k;
};

using A8Extents = metal::extents<int, steelK, tileM>;
using B8Extents = metal::extents<int, tileN, steelK>;
using A16Extents = metal::extents<int, staticK, tileM>;
using B16Extents = metal::extents<int, tileN, staticK>;
using CExtents = metal::extents<int, tileN, tileM>;

METAL_FUNC auto a8_tensor(
    device bfloat* values,
    uint m_origin,
    uint k_origin,
    constant ProblemShape& shape) {
  return metal::tensor(
      values + m_origin * shape.k + k_origin,
      A8Extents{},
      metal::array<int, 2>{1, int(shape.k)});
}

METAL_FUNC auto b8_tensor(
    device bfloat* values,
    uint n_origin,
    uint k_origin,
    constant ProblemShape& shape) {
  return metal::tensor(
      values + k_origin * shape.n + n_origin,
      B8Extents{},
      metal::array<int, 2>{1, int(shape.n)});
}

METAL_FUNC auto a16_tensor(
    device bfloat* values,
    uint m_origin,
    uint k_origin,
    constant ProblemShape& shape) {
  return metal::tensor(
      values + m_origin * shape.k + k_origin,
      A16Extents{},
      metal::array<int, 2>{1, int(shape.k)});
}

METAL_FUNC auto b16_tensor(
    device bfloat* values,
    uint n_origin,
    uint k_origin,
    constant ProblemShape& shape) {
  return metal::tensor(
      values + k_origin * shape.n + n_origin,
      B16Extents{},
      metal::array<int, 2>{1, int(shape.n)});
}

METAL_FUNC auto c_tensor(
    device float* values,
    uint m_origin,
    uint n_origin,
    constant ProblemShape& shape) {
  return metal::tensor(
      values + m_origin * shape.n + n_origin,
      CExtents{},
      metal::array<int, 2>{1, int(shape.n)});
}

// This is the exact legal K=8 schedule that survived the fixed reduction
// probe: dynamic K is inferred from 8-wide tensor inputs, each multiply writes
// an FP32 cooperative destination, and those partials are accumulated
// explicitly in FP32 before the supported cooperative store.
kernel void mpp_dynamic_k8_explicit_fp32(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant ProblemShape& shape [[buffer(3)]],
    uint2 group [[threadgroup_position_in_grid]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      tileM,
      tileN,
      static_cast<int>(metal::dynamic_extent),
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  const uint m_origin = group.y * tileM;
  const uint n_origin = group.x * tileN;
  auto first_a = a8_tensor(a, m_origin, 0, shape);
  auto first_b = b8_tensor(b, n_origin, 0, shape);
  auto accumulator =
      operation.get_destination_cooperative_tensor<
          decltype(first_a),
          decltype(first_b),
          float>();

#pragma clang loop unroll(full)
  for (ushort i = 0; i < accumulator.get_capacity(); ++i) {
    accumulator.set(i, 0.0f);
  }

  for (uint k_origin = 0; k_origin < shape.k; k_origin += steelK) {
    auto a_tile = a8_tensor(a, m_origin, k_origin, shape);
    auto b_tile = b8_tensor(b, n_origin, k_origin, shape);
    auto partial =
        operation.get_destination_cooperative_tensor<
            decltype(a_tile),
            decltype(b_tile),
            float>();
    operation.run(a_tile, b_tile, partial);

#pragma clang loop unroll(full)
    for (ushort i = 0; i < accumulator.get_capacity(); ++i) {
      if (accumulator.is_valid_element(i)) {
        accumulator[i] += partial.get(i);
      }
    }
  }

  auto output_tile = c_tensor(output, m_origin, n_origin, shape);
  accumulator.store(output_tile);
}

// Static K=16 MPP control. Unlike dynamic K, the public API permits explicit
// cooperative input tensors here. Both BF16 operands use the supported load,
// every K=16 product lands in FP32, and accumulation/store are explicit.
kernel void mpp_static_k16_explicit_fp32(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant ProblemShape& shape [[buffer(3)]],
    uint2 group [[threadgroup_position_in_grid]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      tileM,
      tileN,
      staticK,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  const uint m_origin = group.y * tileM;
  const uint n_origin = group.x * tileN;
  auto cooperative_a =
      operation.get_left_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_b =
      operation.get_right_input_cooperative_tensor<bfloat, bfloat, float>();
  auto accumulator =
      operation.get_destination_cooperative_tensor<
          decltype(cooperative_a),
          decltype(cooperative_b),
          float>();

#pragma clang loop unroll(full)
  for (ushort i = 0; i < accumulator.get_capacity(); ++i) {
    accumulator.set(i, 0.0f);
  }

  for (uint k_origin = 0; k_origin < shape.k; k_origin += staticK) {
    auto a_tile = a16_tensor(a, m_origin, k_origin, shape);
    auto b_tile = b16_tensor(b, n_origin, k_origin, shape);
    cooperative_a.load(a_tile);
    cooperative_b.load(b_tile);
    auto partial =
        operation.get_destination_cooperative_tensor<
            decltype(cooperative_a),
            decltype(cooperative_b),
            float>();
    operation.run(cooperative_a, cooperative_b, partial);

#pragma clang loop unroll(full)
    for (ushort i = 0; i < accumulator.get_capacity(); ++i) {
      if (accumulator.is_valid_element(i)) {
        accumulator[i] += partial.get(i);
      }
    }
  }

  auto output_tile = c_tensor(output, m_origin, n_origin, shape);
  accumulator.store(output_tile);
}

// Incumbent arithmetic control: one SIMD group computes the same 16x32 output
// tile as eight 8x8 Steel matrices. BF16 bytes are promoted to the incumbent
// FP32 fragments and reduced in K=8 multiply-accumulate steps.
kernel void steel_k8_explicit_fp32(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant ProblemShape& shape [[buffer(3)]],
    ushort lane [[thread_index_in_simdgroup]],
    uint2 group [[threadgroup_position_in_grid]]) {
  const uint m_origin = group.y * tileM;
  const uint n_origin = group.x * tileN;
  const ushort qid = lane >> 2;
  const uint row = uint((qid & 4) | ((lane >> 1) & 3));
  const uint column = uint(((qid & 2) | (lane & 1)) * 2);

  metal::simdgroup_matrix<float, 8, 8> c00 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  metal::simdgroup_matrix<float, 8, 8> c01 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  metal::simdgroup_matrix<float, 8, 8> c02 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  metal::simdgroup_matrix<float, 8, 8> c03 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  metal::simdgroup_matrix<float, 8, 8> c10 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  metal::simdgroup_matrix<float, 8, 8> c11 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  metal::simdgroup_matrix<float, 8, 8> c12 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  metal::simdgroup_matrix<float, 8, 8> c13 =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);

  for (uint k_origin = 0; k_origin < shape.k; k_origin += steelK) {
    metal::simdgroup_matrix<float, 8, 8> a0;
    metal::simdgroup_matrix<float, 8, 8> a1;
    metal::simdgroup_matrix<float, 8, 8> b0;
    metal::simdgroup_matrix<float, 8, 8> b1;
    metal::simdgroup_matrix<float, 8, 8> b2;
    metal::simdgroup_matrix<float, 8, 8> b3;

    a0.thread_elements()[0] =
        float(a[(m_origin + row) * shape.k + k_origin + column]);
    a0.thread_elements()[1] =
        float(a[(m_origin + row) * shape.k + k_origin + column + 1]);
    a1.thread_elements()[0] =
        float(a[(m_origin + 8 + row) * shape.k + k_origin + column]);
    a1.thread_elements()[1] =
        float(a[(m_origin + 8 + row) * shape.k + k_origin + column + 1]);

    const uint b_row = k_origin + row;
    b0.thread_elements()[0] =
        float(b[b_row * shape.n + n_origin + column]);
    b0.thread_elements()[1] =
        float(b[b_row * shape.n + n_origin + column + 1]);
    b1.thread_elements()[0] =
        float(b[b_row * shape.n + n_origin + 8 + column]);
    b1.thread_elements()[1] =
        float(b[b_row * shape.n + n_origin + 8 + column + 1]);
    b2.thread_elements()[0] =
        float(b[b_row * shape.n + n_origin + 16 + column]);
    b2.thread_elements()[1] =
        float(b[b_row * shape.n + n_origin + 16 + column + 1]);
    b3.thread_elements()[0] =
        float(b[b_row * shape.n + n_origin + 24 + column]);
    b3.thread_elements()[1] =
        float(b[b_row * shape.n + n_origin + 24 + column + 1]);

    metal::simdgroup_multiply_accumulate(c00, a0, b0, c00);
    metal::simdgroup_multiply_accumulate(c01, a0, b1, c01);
    metal::simdgroup_multiply_accumulate(c02, a0, b2, c02);
    metal::simdgroup_multiply_accumulate(c03, a0, b3, c03);
    metal::simdgroup_multiply_accumulate(c10, a1, b0, c10);
    metal::simdgroup_multiply_accumulate(c11, a1, b1, c11);
    metal::simdgroup_multiply_accumulate(c12, a1, b2, c12);
    metal::simdgroup_multiply_accumulate(c13, a1, b3, c13);
  }

#define STORE_STEEL_TILE(matrix, row_offset, column_offset)                 \
  output[(m_origin + row_offset + row) * shape.n +                          \
         n_origin + column_offset + column] = matrix.thread_elements()[0];  \
  output[(m_origin + row_offset + row) * shape.n +                          \
         n_origin + column_offset + column + 1] = matrix.thread_elements()[1]

  STORE_STEEL_TILE(c00, 0, 0);
  STORE_STEEL_TILE(c01, 0, 8);
  STORE_STEEL_TILE(c02, 0, 16);
  STORE_STEEL_TILE(c03, 0, 24);
  STORE_STEEL_TILE(c10, 8, 0);
  STORE_STEEL_TILE(c11, 8, 8);
  STORE_STEEL_TILE(c12, 8, 16);
  STORE_STEEL_TILE(c13, 8, 24);

#undef STORE_STEEL_TILE
}
