#include "benchmark.h"

#include <jaccl/jaccl.h>

#include <array>
#include <charconv>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <unistd.h>

namespace {

int integer(std::string_view text, int low, int high) {
  int value = 0;
  const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
  if (error != std::errc{} || end != text.data() + text.size() || value < low || value > high) {
    throw std::invalid_argument("Expected an integer from " + std::to_string(low)
        + " to " + std::to_string(high));
  }
  return value;
}

void timed_out(int) {
  constexpr char message[] = "{\"schema_version\":1,\"event\":\"error\",\"error\":\"probe timeout\"}\n";
  (void)write(STDERR_FILENO, message, sizeof(message) - 1);
  _exit(124);
}

const char* environment(const char* primary, const char* fallback) {
  const auto value = std::getenv(primary);
  return value ? value : std::getenv(fallback);
}

}  // namespace

int main(int argc, char** argv) {
  int rank = -1;
  try {
    probe::Options options;
    bool self_test = false;
    for (int i = 1; i < argc; ++i) {
      const std::string arg = argv[i];
      if (arg == "--help") {
        std::cout << "cluster-transport-probe [--mode host|metal|both] [--dtype float32|bfloat16] "
                     "[--warmup 5] [--repetitions 30] [--timeout-seconds 120] [--self-test]\n"
                     "Requires JACCL_RANK, JACCL_IBV_DEVICES, JACCL_COORDINATOR "
                     "(or the corresponding MLX variables) for exactly two ranks.\n";
        return 0;
      }
      if (arg == "--self-test") { self_test = true; continue; }
      if (i + 1 >= argc) throw std::invalid_argument("Missing value for " + arg);
      const std::string value = argv[++i];
      if (arg == "--mode") options.mode = value;
      else if (arg == "--dtype") {
        if (value == "float32") options.dtype = jaccl::Float32;
        else if (value == "bfloat16") options.dtype = jaccl::BFloat16;
        else throw std::invalid_argument("Dtype must be float32 or bfloat16");
      }
      else if (arg == "--warmup") options.warmup = integer(value, 0, 10000);
      else if (arg == "--repetitions") options.repetitions = integer(value, 1, 10000);
      else if (arg == "--timeout-seconds") options.timeout_seconds = integer(value, 1, 3600);
      else throw std::invalid_argument("Unknown option: " + arg);
    }
    if (options.mode != "host" && options.mode != "metal" && options.mode != "both") {
      throw std::invalid_argument("Mode must be host, metal, or both");
    }
    std::signal(SIGALRM, timed_out);
    alarm(options.timeout_seconds);
    if (self_test) {
      probe::local_self_test(options);
      alarm(0);
      return 0;
    }
    const auto rank_text = environment("JACCL_RANK", "MLX_RANK");
    if (!rank_text) throw std::invalid_argument("JACCL_RANK or MLX_RANK is required");
    rank = integer(rank_text, 0, 1);
    auto config = jaccl::Config::from_env();
    if (config.get_size() != 2 || !config.is_valid()) {
      throw std::invalid_argument("A valid two-rank JACCL device matrix and coordinator are required");
    }
    auto group = jaccl::init(config, true);
    if (!group || group->size() != 2 || group->rank() != rank) {
      throw std::runtime_error("JACCL did not initialize the requested two-rank group");
    }
    // Reject mismatched runs before entering different collective schedules.
    const std::array<int, 5> arguments = {1, options.warmup, options.repetitions,
        options.mode == "host" ? 0 : options.mode == "metal" ? 1 : 2, options.dtype};
    std::array<int, 10> peer_arguments{};
    group->all_gather(arguments.data(), peer_arguments.data(), sizeof(arguments));
    if (!std::equal(peer_arguments.begin(), peer_arguments.begin() + arguments.size(),
                    peer_arguments.begin() + arguments.size())) {
      throw std::runtime_error("Ranks have mismatched benchmark arguments/schema");
    }
    probe::emit({{"schema_version", 1}, {"event", "start"}, {"rank", rank},
                 {"world_size", 2}, {"backend", "jaccl"},
                 {"topology", config.get_prefer_ring() ? "ring" : "mesh"},
                 {"mode", options.mode}, {"warmup", options.warmup},
                 {"dtype", probe::dtype_name(options.dtype)},
                 {"repetitions", options.repetitions}});
    for (const std::string mode : {"host", "metal"}) {
      if (options.mode != "both" && options.mode != mode) continue;
      for (const auto bytes : probe::message_bytes) {
        probe::emit(probe::run_case(*group, options, mode, bytes));
      }
    }
    group->barrier();
    probe::emit({{"schema_version", 1}, {"event", "complete"}, {"rank", rank},
                 {"correct", true}});
    alarm(0);
    return 0;
  } catch (const std::exception& error) {
    std::cerr << nlohmann::json({{"schema_version", 1}, {"event", "error"},
        {"rank", rank}, {"error", error.what()}}).dump() << std::endl;
    return 1;
  }
}
