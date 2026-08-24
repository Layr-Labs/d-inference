#include <metal_simdgroup_matrix>
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

using namespace metal;
using namespace mpp::tensor_ops;

constant constexpr int probeM = 16;
constant constexpr int probeN = 32;
constant constexpr int probeK = 16;
constant constexpr int steelK = 8;

using ProbeAExtents = metal::extents<int, probeK, probeM>;
using ProbeBExtents = metal::extents<int, probeN, probeK>;
using ProbeBTransposedExtents = metal::extents<int, probeK, probeN>;
using ProbeCExtents = metal::extents<int, probeN, probeM>;
using HalfAExtents = metal::extents<int, steelK, probeM>;
using HalfBExtents = metal::extents<int, probeN, steelK>;

METAL_FUNC auto full_a_tensor(device bfloat* values) {
  return metal::tensor(
      values, ProbeAExtents{}, metal::array<int, 2>{1, probeK});
}

METAL_FUNC auto full_b_tensor(device bfloat* values) {
  return metal::tensor(
      values, ProbeBExtents{}, metal::array<int, 2>{1, probeN});
}

METAL_FUNC auto full_b_transposed_tensor(device bfloat* values) {
  return metal::tensor(
      values,
      ProbeBTransposedExtents{},
      metal::array<int, 2>{probeN, 1});
}

METAL_FUNC auto output_tensor(device float* values) {
  return metal::tensor(
      values, ProbeCExtents{}, metal::array<int, 2>{1, probeN});
}

METAL_FUNC auto half_a_tensor(device bfloat* values, int k_offset) {
  return metal::tensor(
      values + k_offset,
      HalfAExtents{},
      metal::array<int, 2>{1, probeK});
}

METAL_FUNC auto half_b_tensor(device bfloat* values, int k_offset) {
  return metal::tensor(
      values + k_offset * probeN,
      HalfBExtents{},
      metal::array<int, 2>{1, probeN});
}

// MLX BaseNAXFrag's assumed 16x16 per-lane register layout. The M3 MPP
// fallback is free to use a different cooperative-tensor layout.
METAL_FUNC int2 mlx_nax_base_coord(ushort lane) {
  const ushort qid = lane >> 2;
  const int row = int((qid & 4) | ((lane >> 1) & 3));
  const int column = int(((qid & 2) | (lane & 1)) * 4);
  return int2(column, row);
}

kernel void steel_k8x2_reference(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    ushort lane [[thread_index_in_simdgroup]],
    uint2 group [[threadgroup_position_in_grid]]) {
  const int m_origin = int(group.y) * 8;
  const int n_origin = int(group.x) * 8;

  const ushort qid = lane / 4;
  const int row = int((qid & 4) + ((lane / 2) % 4));
  const int column = int((qid & 2) * 2 + (lane % 2) * 2);

  metal::simdgroup_matrix<float, 8, 8> a0;
  metal::simdgroup_matrix<float, 8, 8> a1;
  metal::simdgroup_matrix<float, 8, 8> b0;
  metal::simdgroup_matrix<float, 8, 8> b1;
  metal::simdgroup_matrix<float, 8, 8> zero =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  metal::simdgroup_matrix<float, 8, 8> first;
  metal::simdgroup_matrix<float, 8, 8> second;

  a0.thread_elements()[0] =
      float(a[(m_origin + row) * probeK + column]);
  a0.thread_elements()[1] =
      float(a[(m_origin + row) * probeK + column + 1]);
  a1.thread_elements()[0] =
      float(a[(m_origin + row) * probeK + steelK + column]);
  a1.thread_elements()[1] =
      float(a[(m_origin + row) * probeK + steelK + column + 1]);

  b0.thread_elements()[0] =
      float(b[row * probeN + n_origin + column]);
  b0.thread_elements()[1] =
      float(b[row * probeN + n_origin + column + 1]);
  b1.thread_elements()[0] =
      float(b[(steelK + row) * probeN + n_origin + column]);
  b1.thread_elements()[1] =
      float(b[(steelK + row) * probeN + n_origin + column + 1]);

  metal::simdgroup_multiply_accumulate(first, a0, b0, zero);
  metal::simdgroup_multiply_accumulate(second, a1, b1, first);

  output[(m_origin + row) * probeN + n_origin + column] =
      second.thread_elements()[0];
  output[(m_origin + row) * probeN + n_origin + column + 1] =
      second.thread_elements()[1];
}

kernel void mpp_static_k16_macc_cooperative_inputs(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      probeK,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a_tensor = full_a_tensor(a);
  auto b_tensor = full_b_tensor(b);
  auto c_tensor = output_tensor(output);
  auto cooperative_a =
      operation.get_left_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_b =
      operation.get_right_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_c =
      operation.get_destination_cooperative_tensor<
          decltype(cooperative_a),
          decltype(cooperative_b),
          float>();

  cooperative_a.load(a_tensor);
  cooperative_b.load(b_tensor);
#pragma clang loop unroll(full)
  for (ushort i = 0; i < cooperative_c.get_capacity(); ++i) {
    cooperative_c.set(i, 0.0f);
  }
  operation.run(cooperative_a, cooperative_b, cooperative_c);
  cooperative_c.store(c_tensor);
}

kernel void mpp_static_k16_nt_macc_cooperative_inputs(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      probeK,
      false,
      true,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a_tensor = full_a_tensor(a);
  auto b_tensor = full_b_transposed_tensor(b);
  auto c_tensor = output_tensor(output);
  auto cooperative_a =
      operation.get_left_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_b =
      operation.get_right_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_c =
      operation.get_destination_cooperative_tensor<
          decltype(cooperative_a),
          decltype(cooperative_b),
          float>();

  cooperative_a.load(a_tensor);
  cooperative_b.load(b_tensor);
#pragma clang loop unroll(full)
  for (ushort i = 0; i < cooperative_c.get_capacity(); ++i) {
    cooperative_c.set(i, 0.0f);
  }
  operation.run(cooperative_a, cooperative_b, cooperative_c);
  cooperative_c.store(c_tensor);
}

kernel void mpp_static_k16_nt_macc_mlx_manual_inputs_and_output(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    ushort lane [[thread_index_in_simdgroup]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      probeK,
      false,
      true,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto cooperative_a =
      operation.get_left_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_b =
      operation.get_right_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_c =
      operation.get_destination_cooperative_tensor<
          decltype(cooperative_a),
          decltype(cooperative_b),
          float>();
  const int2 base = mlx_nax_base_coord(lane);

#pragma clang loop unroll(full)
  for (ushort i = 0; i < 8; ++i) {
    const int row = base.y + int(i >> 2) * 8;
    const int column = base.x + int(i & 3);
    cooperative_a[i] = a[row * probeK + column];
    cooperative_b[i] = b[column * probeN + row];
    cooperative_b[8 + i] = b[column * probeN + 16 + row];
  }
#pragma clang loop unroll(full)
  for (ushort i = 0; i < cooperative_c.get_capacity(); ++i) {
    cooperative_c.set(i, 0.0f);
  }
  operation.run(cooperative_a, cooperative_b, cooperative_c);
#pragma clang loop unroll(full)
  for (ushort i = 0; i < 8; ++i) {
    const int row = base.y + int(i >> 2) * 8;
    const int column = base.x + int(i & 3);
    output[row * probeN + column] = cooperative_c[i];
    output[row * probeN + 16 + column] = cooperative_c[8 + i];
  }
}

kernel void mpp_static_k16_macc_mlx_manual_inputs(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    ushort lane [[thread_index_in_simdgroup]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      probeK,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto c_tensor = output_tensor(output);
  auto cooperative_a =
      operation.get_left_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_b =
      operation.get_right_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_c =
      operation.get_destination_cooperative_tensor<
          decltype(cooperative_a),
          decltype(cooperative_b),
          float>();
  const int2 base = mlx_nax_base_coord(lane);

#pragma clang loop unroll(full)
  for (ushort i = 0; i < 8; ++i) {
    const int row = base.y + int(i >> 2) * 8;
    const int column = base.x + int(i & 3);
    cooperative_a[i] = a[row * probeK + column];
    cooperative_b[i] = b[row * probeN + column];
    cooperative_b[8 + i] = b[row * probeN + 16 + column];
  }
#pragma clang loop unroll(full)
  for (ushort i = 0; i < cooperative_c.get_capacity(); ++i) {
    cooperative_c.set(i, 0.0f);
  }
  operation.run(cooperative_a, cooperative_b, cooperative_c);
  cooperative_c.store(c_tensor);
}

kernel void mpp_static_k16_macc_mlx_manual_output(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    ushort lane [[thread_index_in_simdgroup]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      probeK,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a_tensor = full_a_tensor(a);
  auto b_tensor = full_b_tensor(b);
  auto cooperative_a =
      operation.get_left_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_b =
      operation.get_right_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_c =
      operation.get_destination_cooperative_tensor<
          decltype(cooperative_a),
          decltype(cooperative_b),
          float>();
  const int2 base = mlx_nax_base_coord(lane);

  cooperative_a.load(a_tensor);
  cooperative_b.load(b_tensor);
#pragma clang loop unroll(full)
  for (ushort i = 0; i < cooperative_c.get_capacity(); ++i) {
    cooperative_c.set(i, 0.0f);
  }
  operation.run(cooperative_a, cooperative_b, cooperative_c);
#pragma clang loop unroll(full)
  for (ushort i = 0; i < 8; ++i) {
    const int row = base.y + int(i >> 2) * 8;
    const int column = base.x + int(i & 3);
    output[row * probeN + column] = cooperative_c[i];
    output[row * probeN + 16 + column] = cooperative_c[8 + i];
  }
}

kernel void mpp_static_k16_macc_mlx_manual_inputs_and_output(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    ushort lane [[thread_index_in_simdgroup]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      probeK,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto cooperative_a =
      operation.get_left_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_b =
      operation.get_right_input_cooperative_tensor<bfloat, bfloat, float>();
  auto cooperative_c =
      operation.get_destination_cooperative_tensor<
          decltype(cooperative_a),
          decltype(cooperative_b),
          float>();
  const int2 base = mlx_nax_base_coord(lane);

#pragma clang loop unroll(full)
  for (ushort i = 0; i < 8; ++i) {
    const int row = base.y + int(i >> 2) * 8;
    const int column = base.x + int(i & 3);
    cooperative_a[i] = a[row * probeK + column];
    cooperative_b[i] = b[row * probeN + column];
    cooperative_b[8 + i] = b[row * probeN + 16 + column];
  }
#pragma clang loop unroll(full)
  for (ushort i = 0; i < cooperative_c.get_capacity(); ++i) {
    cooperative_c.set(i, 0.0f);
  }
  operation.run(cooperative_a, cooperative_b, cooperative_c);
#pragma clang loop unroll(full)
  for (ushort i = 0; i < 8; ++i) {
    const int row = base.y + int(i >> 2) * 8;
    const int column = base.x + int(i & 3);
    output[row * probeN + column] = cooperative_c[i];
    output[row * probeN + 16 + column] = cooperative_c[8 + i];
  }
}

kernel void mpp_static_k16_macc_tensor_inputs(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      probeK,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a_tensor = full_a_tensor(a);
  auto b_tensor = full_b_tensor(b);
  auto c_tensor = output_tensor(output);
  operation.run(a_tensor, b_tensor, c_tensor);
}

kernel void mpp_static_k16_multiply(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      probeK,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a_tensor = full_a_tensor(a);
  auto b_tensor = full_b_tensor(b);
  auto c_tensor = output_tensor(output);
  operation.run(a_tensor, b_tensor, c_tensor);
}

kernel void mpp_dynamic_k8_staged_macc(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      static_cast<int>(metal::dynamic_extent),
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a0 = half_a_tensor(a, 0);
  auto b0 = half_b_tensor(b, 0);
  auto a1 = half_a_tensor(a, steelK);
  auto b1 = half_b_tensor(b, steelK);
  auto c = output_tensor(output);
  operation.run(a0, b0, c);
  operation.run(a1, b1, c);
}

kernel void mpp_dynamic_k8_multiply_explicit_add(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      static_cast<int>(metal::dynamic_extent),
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a0 = half_a_tensor(a, 0);
  auto b0 = half_b_tensor(b, 0);
  auto a1 = half_a_tensor(a, steelK);
  auto b1 = half_b_tensor(b, steelK);
  auto output_view = output_tensor(output);
  auto c0 =
      operation.get_destination_cooperative_tensor<decltype(a0), decltype(b0), float>();
  auto c1 =
      operation.get_destination_cooperative_tensor<decltype(a1), decltype(b1), float>();

  operation.run(a0, b0, c0);
  operation.run(a1, b1, c1);
#pragma clang loop unroll(full)
  for (ushort i = 0; i < c0.get_capacity(); ++i) {
    if (c0.is_valid_element(i)) {
      c0[i] = c0[i] + c1.get(i);
    }
  }
  c0.store(output_view);
}

kernel void mpp_static_k16_padded_multiply_explicit_add(
    device bfloat* a0_values [[buffer(0)]],
    device bfloat* b0_values [[buffer(1)]],
    device bfloat* a1_values [[buffer(2)]],
    device bfloat* b1_values [[buffer(3)]],
    device float* output [[buffer(4)]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      probeM,
      probeN,
      probeK,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a0 = full_a_tensor(a0_values);
  auto b0 = full_b_tensor(b0_values);
  auto a1 = full_a_tensor(a1_values);
  auto b1 = full_b_tensor(b1_values);
  auto output_view = output_tensor(output);
  auto c0 =
      operation.get_destination_cooperative_tensor<decltype(a0), decltype(b0), float>();
  auto c1 =
      operation.get_destination_cooperative_tensor<decltype(a1), decltype(b1), float>();

  operation.run(a0, b0, c0);
  operation.run(a1, b1, c1);
#pragma clang loop unroll(full)
  for (ushort i = 0; i < c0.get_capacity(); ++i) {
    if (c0.is_valid_element(i)) {
      c0[i] = c0[i] + c1.get(i);
    }
  }
  c0.store(output_view);
}
