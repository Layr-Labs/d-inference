#pragma once

#include <jaccl/group.h>
#include <jaccl/types.h>
#include <nlohmann/json.hpp>

#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace probe {

struct Options {
  int warmup = 5;
  int repetitions = 30;
  int timeout_seconds = 120;
  std::string mode = "both";
  int dtype = jaccl::Float32;
};

inline constexpr std::size_t message_bytes[] = {
    10 * 1024, 1024 * 1024, 5 * 1024 * 1024,
    10 * 1024 * 1024, 20 * 1024 * 1024};

// Small exactly representable values make every output element checkable.
inline float input_value(std::size_t index, int rank) {
  return float(rank + 1) + float(index % 31) / 16.0f;
}
inline float reduced_value(std::size_t index) {
  return 3.0f + float(index % 31) / 8.0f;
}
inline std::size_t scalar_bytes(int dtype) { return dtype == jaccl::Float32 ? 4 : 2; }
inline const char* dtype_name(int dtype) { return dtype == jaccl::Float32 ? "float32" : "bfloat16"; }

class Buffers {
 public:
  virtual ~Buffers() = default;
  virtual const void* input() const = 0;
  virtual void* output() = 0;
  virtual void prepare() {}
  virtual void produce() = 0;
  virtual void consume() = 0;
  virtual void check() const = 0;
  virtual std::string device_name() const { return "CPU"; }
};

std::unique_ptr<Buffers> make_metal_buffers(std::size_t bytes, int rank, int dtype);
void check_values(const void* values, std::size_t count, int dtype, bool consumed);
void local_self_test(const Options& options);
nlohmann::json run_case(jaccl::Group& group, const Options& options,
                        const std::string& mode, std::size_t bytes);
void emit(const nlohmann::json& record);

}  // namespace probe
