#include "benchmark.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace probe {
namespace {

constexpr const char* kernels = R"metal(
#include <metal_stdlib>
using namespace metal;
kernel void produce(device float* output [[buffer(0)]],
                    constant uint& rank [[buffer(1)]],
                    uint i [[thread_position_in_grid]]) {
  output[i] = float(rank + 1) + float(i % 31) / 16.0f;
}
kernel void consume(device const float* input [[buffer(0)]],
                    device float* output [[buffer(1)]],
                    uint i [[thread_position_in_grid]]) {
  output[i] = 2.0f * input[i] + 1.0f;
}
// Integer bit conversions avoid depending on native GPU bfloat support. The
// chosen values and their sums are all exactly representable in bfloat16.
kernel void produce_bf16(device ushort* output [[buffer(0)]],
                         constant uint& rank [[buffer(1)]],
                         uint i [[thread_position_in_grid]]) {
  float value = float(rank + 1) + float(i % 31) / 16.0f;
  output[i] = ushort(as_type<uint>(value) >> 16);
}
kernel void consume_bf16(device const ushort* input [[buffer(0)]],
                         device ushort* output [[buffer(1)]],
                         uint i [[thread_position_in_grid]]) {
  float value = as_type<float>(uint(input[i]) << 16);
  output[i] = ushort(as_type<uint>(2.0f * value + 1.0f) >> 16);
}
)metal";

std::string message(NSError* error) {
  return error ? std::string(error.localizedDescription.UTF8String) : "unknown Metal error";
}

class MetalBuffers final : public Buffers {
 public:
  MetalBuffers(std::size_t bytes, int rank, int dtype)
      : count_(bytes / scalar_bytes(dtype)), rank_(rank), dtype_(dtype) {
    @autoreleasepool {
      device_ = MTLCreateSystemDefaultDevice();
      if (!device_ || !device_.hasUnifiedMemory) {
        throw std::runtime_error("Metal mode requires a unified-memory GPU");
      }
      queue_ = [device_ newCommandQueue];
      input_ = [device_ newBufferWithLength:bytes options:MTLResourceStorageModeShared];
      output_ = [device_ newBufferWithLength:bytes options:MTLResourceStorageModeShared];
      consumed_ = [device_ newBufferWithLength:bytes options:MTLResourceStorageModeShared];
      if (!queue_ || !input_ || !output_ || !consumed_) {
        throw std::runtime_error("Metal buffer/queue allocation failed");
      }
      NSError* error = nil;
      auto library = [device_ newLibraryWithSource:@(kernels) options:nil error:&error];
      if (!library) throw std::runtime_error(message(error));
      NSString* producer_name = dtype == jaccl::Float32 ? @"produce" : @"produce_bf16";
      NSString* consumer_name = dtype == jaccl::Float32 ? @"consume" : @"consume_bf16";
      producer_ = [device_ newComputePipelineStateWithFunction:[library newFunctionWithName:producer_name] error:&error];
      if (!producer_) throw std::runtime_error(message(error));
      consumer_ = [device_ newComputePipelineStateWithFunction:[library newFunctionWithName:consumer_name] error:&error];
      if (!consumer_) throw std::runtime_error(message(error));
    }
  }

  const void* input() const override { return input_.contents; }
  void* output() override { return output_.contents; }
  std::string device_name() const override { return device_.name.UTF8String; }
  void prepare() override {
    // A skipped producer or consumer must not pass using the previous result.
    std::memset(input_.contents, 0xff, input_.length);
    std::memset(consumed_.contents, 0xff, consumed_.length);
  }
  void produce() override { dispatch(true); }
  void consume() override { dispatch(false); }
  void check() const override {
    check_values(output_.contents, count_, dtype_, false);
    check_values(consumed_.contents, count_, dtype_, true);
  }

 private:
  void dispatch(bool producing) {
    @autoreleasepool {
      auto command = [queue_ commandBuffer];
      auto encoder = [command computeCommandEncoder];
      auto pipeline = producing ? producer_ : consumer_;
      if (!command || !encoder) throw std::runtime_error("Metal command creation failed");
      [encoder setComputePipelineState:pipeline];
      if (producing) {
        [encoder setBuffer:input_ offset:0 atIndex:0];
        [encoder setBytes:&rank_ length:sizeof(rank_) atIndex:1];
      } else {
        [encoder setBuffer:output_ offset:0 atIndex:0];
        [encoder setBuffer:consumed_ offset:0 atIndex:1];
      }
      const auto threads = std::min<NSUInteger>(256, pipeline.maxTotalThreadsPerThreadgroup);
      [encoder dispatchThreads:MTLSizeMake(count_, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
      [encoder endEncoding];
      [command commit];
      // Shared memory still needs a GPU completion fence before CPU/RDMA use.
      [command waitUntilCompleted];
      if (command.status != MTLCommandBufferStatusCompleted) {
        throw std::runtime_error(message(command.error));
      }
    }
  }

  std::size_t count_;
  uint32_t rank_;
  int dtype_;
  id<MTLDevice> device_;
  id<MTLCommandQueue> queue_;
  id<MTLBuffer> input_, output_, consumed_;
  id<MTLComputePipelineState> producer_, consumer_;
};

}  // namespace

std::unique_ptr<Buffers> make_metal_buffers(std::size_t bytes, int rank, int dtype) {
  return std::make_unique<MetalBuffers>(bytes, rank, dtype);
}

}  // namespace probe
