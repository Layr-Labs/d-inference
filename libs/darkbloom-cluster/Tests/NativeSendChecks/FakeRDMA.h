#pragma once
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <optional>
#include <stdexcept>
#include "jaccl/rdma.h"

namespace fixture {
constexpr unsigned char sentinel = 0xa7;
struct Frame {
  int rank, side, wire;
  std::vector<char> bytes;
};
struct Pending {
  ibv_sge entry;
  uint64_t id;
  std::vector<char> original;
};
struct Completion {
  ibv_wc value;
  std::optional<Pending> send;
};
struct Endpoint;
struct Fabric {
  std::mutex mutex;
  std::condition_variable changed;
  std::vector<std::unique_ptr<Endpoint>> endpoints;
  std::vector<Frame> frames;
  const std::chrono::steady_clock::time_point deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(8);
  void pair(jaccl::Connection&, jaccl::Connection&, int wire, int firstSide = 0);
  void match(Endpoint&);
  void requireDrained();
};
struct Endpoint {
  Fabric* fabric;
  Endpoint* peer = nullptr;
  int rank, side, wire;
  std::deque<Pending> sends, receives;
  std::deque<Completion> completions;
};
inline void require(bool value, const char* message) {
  if (!value) { throw std::runtime_error(message); }
}
} // namespace fixture
