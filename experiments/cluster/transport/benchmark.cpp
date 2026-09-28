#include "benchmark.h"

#include <jaccl/types.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>

namespace probe {
namespace {

using Clock = std::chrono::steady_clock;

double microseconds(Clock::time_point start, Clock::time_point end) {
  return std::chrono::duration<double, std::micro>(end - start).count();
}

template <typename T>
class HostBuffers final : public Buffers {
 public:
  HostBuffers(std::size_t bytes, int rank, int dtype)
      : input_(bytes / sizeof(T), T(0.0f)), output_(input_.size(), T(0.0f)), dtype_(dtype) {
    for (std::size_t i = 0; i < input_.size(); ++i) {
      input_[i] = T(input_value(i, rank));
    }
  }
  const void* input() const override { return input_.data(); }
  void* output() override { return output_.data(); }
  void produce() override {}
  void consume() override {}
  void check() const override {
    check_values(output_.data(), output_.size(), dtype_, false);
  }

 private:
  std::vector<T> input_;
  std::vector<T> output_;
  int dtype_;
};

std::unique_ptr<Buffers> make_buffers(const std::string& mode, std::size_t bytes,
                                    int rank, int dtype) {
  if (mode == "metal") return make_metal_buffers(bytes, rank, dtype);
  if (dtype == jaccl::Float32) return std::make_unique<HostBuffers<float>>(bytes, rank, dtype);
  return std::make_unique<HostBuffers<jaccl::bfloat16_t>>(bytes, rank, dtype);
}

float read_value(const void* values, std::size_t index, int dtype) {
  return dtype == jaccl::Float32 ? static_cast<const float*>(values)[index]
      : float(static_cast<const jaccl::bfloat16_t*>(values)[index]);
}

void write_value(void* values, std::size_t index, int dtype, float value) {
  if (dtype == jaccl::Float32) static_cast<float*>(values)[index] = value;
  else static_cast<jaccl::bfloat16_t*>(values)[index] = jaccl::bfloat16_t(value);
}

nlohmann::json summarize(std::vector<double> samples, std::size_t bytes) {
  std::sort(samples.begin(), samples.end());
  const auto n = samples.size();
  const double median = n % 2 ? samples[n / 2]
      : (samples[n / 2 - 1] + samples[n / 2]) / 2;
  const double p95 = samples[std::size_t(std::ceil(0.95 * n)) - 1];
  return {{"median_us", median}, {"p95_us", p95},
          {"min_us", samples.front()}, {"max_us", samples.back()},
          {"payload_GBps_at_median", double(bytes) / (median * 1000)},
          {"payload_GBps_at_p95", double(bytes) / (p95 * 1000)}};
}

}  // namespace

void emit(const nlohmann::json& record) {
  std::cout << record.dump() << std::endl;
}

void check_values(const void* values, std::size_t count, int dtype, bool consumed) {
  for (std::size_t i = 0; i < count; ++i) {
    const float expected = consumed ? 2 * reduced_value(i) + 1 : reduced_value(i);
    const float actual = read_value(values, i, dtype);
    if (actual != expected) {
      throw std::runtime_error("Incorrect " + std::string(consumed ? "GPU-consumed" : "reduced")
          + " value at element " + std::to_string(i) + ": expected "
          + std::to_string(expected) + ", got " + std::to_string(actual));
    }
  }
}

nlohmann::json run_case(jaccl::Group& group, const Options& options,
                        const std::string& mode, std::size_t bytes) {
  auto buffers = make_buffers(mode, bytes, group.rank(), options.dtype);
  std::vector<double> total, collective, producer, consumer;
  const int iterations = options.warmup + options.repetitions;
  for (int i = 0; i < iterations; ++i) {
    // Poison outside the timed region so an unwritten output is never accepted.
    std::memset(buffers->output(), 0xff, bytes);  // NaN for both supported dtypes.
    buffers->prepare();
    group.barrier();
    const auto start = Clock::now();
    buffers->produce();
    const auto produced = Clock::now();
    group.all_sum(buffers->input(), buffers->output(), bytes, options.dtype);
    const auto reduced = Clock::now();
    buffers->consume();
    const auto end = Clock::now();
    buffers->check();
    if (i >= options.warmup) {
      total.push_back(microseconds(start, end));
      collective.push_back(microseconds(produced, reduced));
      producer.push_back(microseconds(start, produced));
      consumer.push_back(microseconds(reduced, end));
    }
  }
  // Both ranks use this same order. Max of each paired sample approximates
  // the critical path; per-rank samples remain available for skew analysis.
  std::vector<double> gathered_total(2 * total.size());
  std::vector<double> gathered_collective(2 * collective.size());
  group.all_gather(total.data(), gathered_total.data(), total.size() * sizeof(double));
  group.all_gather(collective.data(), gathered_collective.data(), collective.size() * sizeof(double));
  std::vector<double> max_total(total.size()), max_collective(total.size());
  for (std::size_t i = 0; i < total.size(); ++i) {
    max_total[i] = std::max(gathered_total[i], gathered_total[i + total.size()]);
    max_collective[i] = std::max(gathered_collective[i], gathered_collective[i + total.size()]);
  }
  return {{"schema_version", 1}, {"event", "measurement"},
          {"rank", group.rank()}, {"world_size", group.size()},
          {"mode", mode}, {"device", buffers->device_name()},
          {"dtype", dtype_name(options.dtype)}, {"bytes", bytes},
          {"warmup", options.warmup}, {"repetitions", options.repetitions},
          {"correct", true}, {"checked_iterations", iterations},
          {"total", summarize(total, bytes)},
          {"collective", summarize(collective, bytes)},
          {"rank_max_total", summarize(max_total, bytes)},
          {"rank_max_collective", summarize(max_collective, bytes)},
          {"samples_us", {{"total", total}, {"collective", collective},
                           {"producer", producer}, {"consumer", consumer}}}};
}

void local_self_test(const Options& options) {
  for (const std::string mode : {"host", "metal"}) {
    if (options.mode != "both" && options.mode != mode) continue;
    for (const auto bytes : message_bytes) {
      auto first = make_buffers(mode, bytes, 0, options.dtype);
      auto second = make_buffers(mode, bytes, 1, options.dtype);
      first->prepare();
      second->prepare();
      first->produce();
      second->produce();
      const auto count = bytes / scalar_bytes(options.dtype);
      for (std::size_t i = 0; i < count; ++i) {
        const auto a = read_value(first->input(), i, options.dtype);
        const auto b = read_value(second->input(), i, options.dtype);
        if (a != input_value(i, 0) || b != input_value(i, 1)) {
          throw std::runtime_error("Incorrect local producer at element " + std::to_string(i));
        }
        write_value(first->output(), i, options.dtype, a + b);
        write_value(second->output(), i, options.dtype, a + b);
      }
      first->consume();
      second->consume();
      first->check();
      second->check();
      emit({{"schema_version", 1}, {"event", "local_self_test"},
            {"mode", mode}, {"dtype", dtype_name(options.dtype)},
            {"bytes", bytes}, {"correct", true}, {"rdma_tested", false}});
    }
  }
}

}  // namespace probe
