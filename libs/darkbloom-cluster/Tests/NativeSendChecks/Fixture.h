#pragma once
#include <array>
#include <future>
#include "FakeRDMA.h"
#include "jaccl/mesh_impl.h"
#include "jaccl/ring_impl.h"

namespace fixture {
struct StaleTail : std::runtime_error {
  StaleTail() : std::runtime_error("Nonzero stale/native scratch tail") {}
};
inline void zeroTail(const Frame& frame, size_t logical) {
  require(logical <= frame.bytes.size(), "Logical frame exceeds native frame");
  for (size_t index = logical; index < frame.bytes.size(); ++index) {
    if (frame.bytes[index] != 0) { throw StaleTail(); }
  }
}
template <typename First, typename Second>
void both(First first, Second second) {
  auto a = std::async(std::launch::async, first);
  auto b = std::async(std::launch::async, second);
  std::exception_ptr error;
  try { a.get(); } catch (...) { error = std::current_exception(); }
  try { b.get(); } catch (...) { if (!error) { error = std::current_exception(); } }
  if (error) { std::rethrow_exception(error); }
}
inline void connections(std::vector<jaccl::Connection>& values, int count) {
  values.reserve(count);
  for (int i = 0; i < count; ++i) { values.emplace_back(nullptr); }
}
inline void buffers(std::vector<jaccl::SharedBuffer>& values, int slots,
    const std::vector<jaccl::Connection>& first,
    const std::vector<jaccl::Connection>* second = nullptr) {
  values.reserve(BUFFER_SIZES * slots);
  for (int size = 0; size < BUFFER_SIZES; ++size) {
    for (int slot = 0; slot < slots; ++slot) {
      values.emplace_back(FRAME_SIZE * (1 << size));
      for (const auto& connection : first) {
        if (connection.ctx) { values.back().register_to_protection_domain(connection.protection_domain); }
      }
      if (second) {
        for (const auto& connection : *second) {
          values.back().register_to_protection_domain(connection.protection_domain);
        }
      }
    }
  }
}
struct MeshPair {
  Fabric fabric;
  std::array<std::vector<jaccl::Connection>, 2> links;
  std::array<std::vector<jaccl::SharedBuffer>, 2> scratch, scatter;
  std::array<std::unique_ptr<jaccl::MeshImpl>, 2> nodes;
  MeshPair() {
    for (auto& rank : links) { connections(rank, 2); }
    fabric.pair(links[0][1], links[1][0], 0);
    for (int rank = 0; rank < 2; ++rank) {
      buffers(scratch[rank], NUM_BUFFERS * 2, links[rank]);
      buffers(scatter[rank], NUM_BUFFERS * 4, links[rank]);
      nodes[rank] = std::make_unique<jaccl::MeshImpl>(rank, 2,
          links[rank], scratch[rank], scatter[rank]);
    }
  }
};
struct RingPair {
  Fabric fabric;
  int wires;
  std::array<std::vector<jaccl::Connection>, 2> left, right;
  std::array<std::vector<jaccl::SharedBuffer>, 2> sends, receives;
  std::array<std::unique_ptr<jaccl::ThreadPool>, 2> pools;
  std::array<std::unique_ptr<jaccl::RingImpl>, 2> nodes;
  explicit RingPair(int count) : wires(count) {
    for (int rank = 0; rank < 2; ++rank) {
      connections(left[rank], wires); connections(right[rank], wires);
    }
    for (int wire = 0; wire < wires; ++wire) {
      fabric.pair(right[0][wire], left[1][wire], wire, 0);
      fabric.pair(left[0][wire], right[1][wire], wire, 1);
    }
    for (int rank = 0; rank < 2; ++rank) {
      buffers(sends[rank], NUM_BUFFERS * wires * 2, left[rank], &right[rank]);
      buffers(receives[rank], NUM_BUFFERS * wires * 2, left[rank], &right[rank]);
      if (wires > 1) { pools[rank] = std::make_unique<jaccl::ThreadPool>(wires - 1); }
      nodes[rank] = std::make_unique<jaccl::RingImpl>(rank, 2, left[rank], right[rank],
          sends[rank], receives[rank], pools[rank].get());
    }
  }
};
inline std::vector<Frame> selected(const Fabric& fabric, int rank, int side, int wire) {
  std::vector<Frame> result;
  for (const auto& frame : fabric.frames) {
    if (frame.rank == rank && frame.side == side && frame.wire == wire) { result.push_back(frame); }
  }
  return result;
}
inline void payloadFrames(const std::vector<Frame>& frames, std::span<const char> input) {
  const size_t capacity = buffer_size_from_message(input.size()).second;
  require(frames.size() == (input.size() + capacity - 1) / capacity, "Native frame count changed");
  size_t offset = 0;
  for (const auto& frame : frames) {
    require(frame.bytes.size() == capacity, "Native SGE capacity changed");
    const size_t count = std::min(capacity, input.size() - offset);
    require(std::equal(input.begin() + offset, input.begin() + offset + count,
        frame.bytes.begin()), "Valid payload bytes changed");
    zeroTail(frame, count); offset += count;
  }
}
struct Add {
  void operator()(const float* source, float* target, int64_t count) const {
    for (int64_t i = 0; i < count; ++i) { target[i] += source[i]; }
  }
  void operator()(const float* source, const float* base, float* target, int64_t count) const {
    for (int64_t i = 0; i < count; ++i) { target[i] = source[i] + base[i]; }
  }
};
} // namespace fixture
