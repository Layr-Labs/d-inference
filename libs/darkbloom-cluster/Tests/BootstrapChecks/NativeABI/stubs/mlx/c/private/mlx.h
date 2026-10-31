#pragma once
#include <array>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include "mlx/c/distributed_group.h"

// Test-only native factory/cache stand-in. No MLX or RDMA work is linked.
namespace mlx::core::distributed {
using AllGatherFn = std::function<void(const char*, char*, size_t)>;
using AllGatherFactory = std::function<AllGatherFn(int,int)>;
struct Group { std::shared_ptr<AllGatherFn> callback; };
inline Group cache;
inline int test_rank = 0;
inline Group init(bool strict, const std::string& backend, AllGatherFactory factory) {
  if (!strict || backend != "jaccl") { throw std::runtime_error("wrong init"); }
  if (cache.callback) { return cache; }
  auto callback = std::make_shared<AllGatherFn>(factory(test_rank, 2));
  const std::array<char,4> src{1,2,3,4}; std::array<char,8> dst{};
  (*callback)(src.data(),dst.data(),src.size());
  cache = Group{callback}; return cache;
}
}
inline void mlx_distributed_group_set_(mlx_distributed_group& target, mlx::core::distributed::Group group) {
  if (target.ctx) { delete static_cast<mlx::core::distributed::Group*>(target.ctx); }
  target.ctx = new mlx::core::distributed::Group(std::move(group));
}
