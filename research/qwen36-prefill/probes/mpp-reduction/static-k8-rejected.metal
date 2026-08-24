#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

using namespace metal;
using namespace mpp::tensor_ops;

// This file is an expected compile failure. The run script verifies that the
// macOS 26.4/26.5 SDK rejects a static BF16 K=8 descriptor for SIMD-group MPP.
kernel void static_k8_is_not_legal(
    const device bfloat* a [[buffer(0)]],
    const device bfloat* b [[buffer(1)]],
    device float* c [[buffer(2)]]) {
  constexpr auto descriptor = matmul2d_descriptor(
      16,
      32,
      8,
      false,
      false,
      false,
      matmul2d_descriptor::mode::multiply);
  matmul2d<descriptor, metal::execution_simdgroup> operation;

  auto a_tensor = metal::tensor(
      a, metal::extents<int, 8, 16>{}, metal::array<int, 2>{1, 8});
  auto b_tensor = metal::tensor(
      b, metal::extents<int, 32, 8>{}, metal::array<int, 2>{1, 32});
  auto c_tensor = metal::tensor(
      c, metal::extents<int, 32, 16>{}, metal::array<int, 2>{1, 32});
  operation.run(a_tensor, b_tensor, c_tensor);
}
