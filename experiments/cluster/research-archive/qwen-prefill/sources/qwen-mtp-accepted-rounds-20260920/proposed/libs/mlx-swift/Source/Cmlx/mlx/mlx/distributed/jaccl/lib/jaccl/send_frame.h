// Copyright © 2026 Apple Inc.

#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <span>
#include <stdexcept>

namespace jaccl {

// The posted receive/send size stays fixed. Clear every byte after this payload.
template <typename T>
inline void stage_send_frame(
    std::span<char> destination,
    const T* source,
    int64_t count) {
  if (destination.empty() || destination.data() == nullptr || count < 0 ||
      static_cast<uint64_t>(count) > destination.size() / sizeof(T) ||
      (count > 0 && source == nullptr)) {
    throw std::invalid_argument("[jaccl] Send payload exceeds its scratch frame");
  }
  const size_t bytes = static_cast<size_t>(count) * sizeof(T);
  if (count > 0) {
    std::copy_n(source, count, reinterpret_cast<T*>(destination.data()));
  }
  if (bytes < destination.size()) {
    std::memset(destination.data() + bytes, 0, destination.size() - bytes);
  }
}

} // namespace jaccl
