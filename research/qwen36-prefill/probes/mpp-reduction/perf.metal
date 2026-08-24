#include <metal_simdgroup_matrix>
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

using namespace metal;
using namespace mpp::tensor_ops;

constant constexpr int perfM = 16;
constant constexpr int perfN = 32;
constant constexpr int perfK = 16;
constant constexpr int perfHalfK = 8;
constant constexpr int perfRepeats = 128;

using PerfAExtents = metal::extents<int, perfK, perfM>;
using PerfBExtents = metal::extents<int, perfN, perfK>;
using PerfCExtents = metal::extents<int, perfN, perfM>;
using PerfHalfAExtents = metal::extents<int, perfHalfK, perfM>;
using PerfHalfBExtents = metal::extents<int, perfN, perfHalfK>;

METAL_FUNC auto perf_a_tensor(device bfloat* values) {
  return metal::tensor(
      values, PerfAExtents{}, metal::array<int, 2>{1, perfK});
}

METAL_FUNC auto perf_b_tensor(device bfloat* values) {
  return metal::tensor(
      values, PerfBExtents{}, metal::array<int, 2>{1, perfN});
}

METAL_FUNC auto perf_c_tensor(device float* values) {
  return metal::tensor(
      values, PerfCExtents{}, metal::array<int, 2>{1, perfN});
}

METAL_FUNC auto perf_half_a_tensor(device bfloat* values, int offset) {
  return metal::tensor(
      values + offset,
      PerfHalfAExtents{},
      metal::array<int, 2>{1, perfK});
}

METAL_FUNC auto perf_half_b_tensor(device bfloat* values, int offset) {
  return metal::tensor(
      values + offset * perfN,
      PerfHalfBExtents{},
      metal::array<int, 2>{1, perfN});
}

kernel void perf_mpp_static_k16(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    uint group [[threadgroup_position_in_grid]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      perfM,
      perfN,
      perfK,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a_tensor = perf_a_tensor(a);
  auto b_tensor = perf_b_tensor(b);
  auto c_tensor = perf_c_tensor(output + size_t(group) * perfM * perfN);
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
#pragma clang loop unroll(disable)
  for (int iteration = 0; iteration < perfRepeats; ++iteration) {
    operation.run(cooperative_a, cooperative_b, cooperative_c);
  }
  cooperative_c.store(c_tensor);
}

kernel void perf_mpp_dynamic_k8(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    uint group [[threadgroup_position_in_grid]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      perfM,
      perfN,
      static_cast<int>(metal::dynamic_extent),
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply_accumulate);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a0 = perf_half_a_tensor(a, 0);
  auto b0 = perf_half_b_tensor(b, 0);
  auto a1 = perf_half_a_tensor(a, perfHalfK);
  auto b1 = perf_half_b_tensor(b, perfHalfK);
  auto c_tensor = perf_c_tensor(output + size_t(group) * perfM * perfN);
  auto cooperative_c =
      operation.get_destination_cooperative_tensor<
          decltype(a0),
          decltype(b0),
          float>();
#pragma clang loop unroll(full)
  for (ushort i = 0; i < cooperative_c.get_capacity(); ++i) {
    cooperative_c.set(i, 0.0f);
  }
#pragma clang loop unroll(disable)
  for (int iteration = 0; iteration < perfRepeats; ++iteration) {
    operation.run(a0, b0, cooperative_c);
    operation.run(a1, b1, cooperative_c);
  }
  cooperative_c.store(c_tensor);
}

kernel void perf_steel_k8x2(
    device bfloat* a [[buffer(0)]],
    device bfloat* b [[buffer(1)]],
    device float* output [[buffer(2)]],
    ushort lane [[thread_index_in_simdgroup]],
    uint group [[threadgroup_position_in_grid]]) {
  const uint tile = group / 8;
  const uint subtile = group % 8;
  const int m_origin = int(subtile / 4) * 8;
  const int n_origin = int(subtile % 4) * 8;

  const ushort qid = lane / 4;
  const int row = int((qid & 4) + ((lane / 2) % 4));
  const int column = int((qid & 2) * 2 + (lane % 2) * 2);

  metal::simdgroup_matrix<float, 8, 8> a0;
  metal::simdgroup_matrix<float, 8, 8> a1;
  metal::simdgroup_matrix<float, 8, 8> b0;
  metal::simdgroup_matrix<float, 8, 8> b1;
  metal::simdgroup_matrix<float, 8, 8> accumulator =
      metal::make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
  metal::simdgroup_matrix<float, 8, 8> partial;

  a0.thread_elements()[0] =
      float(a[(m_origin + row) * perfK + column]);
  a0.thread_elements()[1] =
      float(a[(m_origin + row) * perfK + column + 1]);
  a1.thread_elements()[0] =
      float(a[(m_origin + row) * perfK + perfHalfK + column]);
  a1.thread_elements()[1] =
      float(a[(m_origin + row) * perfK + perfHalfK + column + 1]);

  b0.thread_elements()[0] =
      float(b[row * perfN + n_origin + column]);
  b0.thread_elements()[1] =
      float(b[row * perfN + n_origin + column + 1]);
  b1.thread_elements()[0] =
      float(b[(perfHalfK + row) * perfN + n_origin + column]);
  b1.thread_elements()[1] =
      float(b[(perfHalfK + row) * perfN + n_origin + column + 1]);

#pragma clang loop unroll(disable)
  for (int iteration = 0; iteration < perfRepeats; ++iteration) {
    metal::simdgroup_multiply_accumulate(partial, a0, b0, accumulator);
    metal::simdgroup_multiply_accumulate(accumulator, a1, b1, partial);
  }

  const size_t output_base = size_t(tile) * perfM * perfN;
  output[output_base + (m_origin + row) * perfN + n_origin + column] =
      accumulator.thread_elements()[0];
  output[output_base + (m_origin + row) * perfN + n_origin + column + 1] =
      accumulator.thread_elements()[1];
}
