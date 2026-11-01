#include <algorithm>
#include <array>
#include <functional>
#include <iostream>
#include <memory>
#include <thread>
#include "distributed_bootstrap.h"

using mlx::c::detail::BootstrapContext;
using mlx::c::detail::BootstrapState;
struct Probe {
  int released = 0;
  int calls = 0;
  bool fail = false;
  bool corrupt = false;
  std::vector<uint64_t> sequences;
};
void release(void* p) { ++static_cast<Probe*>(p)->released; }
int exchange(void* p, int rank, int size, uint64_t seq, const char* src, size_t n, char* dst, size_t total) {
  auto& value = *static_cast<Probe*>(p);
  ++value.calls; value.sequences.push_back(seq);
  if (total != n * static_cast<size_t>(size)) { return 1; }
  std::fill(dst, dst + total, 'z');
  std::copy(src, src + n, dst + rank * n);
  if (value.corrupt) { dst[rank * n] ^= 1; }
  return value.fail ? 1 : 0;
}
void require(bool pass) { if (!pass) { throw std::runtime_error("fixture failed"); } }
template<class F> void rejects(F f) {
  bool failed = false;
  try { f(); } catch (const std::exception&) { failed = true; }
  require(failed);
}
std::shared_ptr<BootstrapState> make(Probe& p, int rank = 0) {
  return std::make_shared<BootstrapState>(BootstrapContext(&p, release), rank, 2, 8, 16, exchange);
}
int main() {
  int checks = 0;
  {
    Probe p; auto state = make(p); state->bind(0, 2); state->require_fresh();
    std::array<char,4> src{'a','b','c','d'}; std::array<char,8> dst{};
    state->all_gather(src.data(), dst.data(), src.size());
    state->all_gather(src.data(), dst.data(), src.size());
    require(std::equal(src.begin(), src.end(), dst.begin()) && dst[4] == 'z');
    require(p.sequences == std::vector<uint64_t>({0,1})); state.reset(); require(p.released == 1); ++checks;
  }
  {
    Probe p; auto state = make(p, 1); state->bind(1,2);
    std::array<char,2> src{'x','y'}; std::array<char,4> dst{};
    state->all_gather(src.data(), dst.data(), src.size());
    require(dst[0] == 'z' && dst[2] == 'x' && dst[3] == 'y'); ++checks;
  }
  {
    Probe p; auto state = make(p);
    rejects([&] { state->require_fresh(); }); require(p.calls == 0); ++checks;
  }
  {
    Probe p; auto state = make(p); rejects([&] { state->bind(1,2); });
    rejects([&] { state->bind(0,2); }); require(p.calls == 0); ++checks;
  }
  {
    Probe p; auto state = make(p); state->bind(0,2);
    rejects([&] { state->bind(0,2); }); rejects([&] { state->require_fresh(); }); ++checks;
  }
  {
    Probe p; p.fail = true; auto state = make(p); state->bind(0,2);
    std::array<char,2> src{'a','b'}; std::array<char,4> dst{'q','q','q','q'};
    rejects([&] { state->all_gather(src.data(),dst.data(),src.size()); });
    require(dst == std::array<char,4>({'q','q','q','q'}));
    p.fail = false; rejects([&] { state->all_gather(src.data(),dst.data(),src.size()); });
    require(p.calls == 1); ++checks;
  }
  {
    Probe p; p.corrupt = true; auto state = make(p); state->bind(0,2);
    std::array<char,2> src{'a','b'}; std::array<char,4> dst{'q','q','q','q'};
    rejects([&] { state->all_gather(src.data(),dst.data(),src.size()); });
    require(dst[0] == 'q' && p.calls == 1); ++checks;
  }
  {
    Probe p; auto state = make(p); state->bind(0,2);
    std::array<char,9> src{}; std::array<char,18> dst{};
    rejects([&] { state->all_gather(src.data(),dst.data(),src.size()); }); require(p.calls == 0); ++checks;
  }
  {
    Probe p; auto state = make(p); state->bind(0,2);
    rejects([&] { state->all_gather(nullptr,nullptr,0); }); require(p.calls == 0); ++checks;
  }
  {
    Probe p;
    rejects([&] { BootstrapState state(BootstrapContext(&p, release), 0, 2, 9, 16, exchange); });
    require(p.released == 1); ++checks;
  }
  {
    Probe p; auto state = make(p); state->bind(0,2);
    std::function<void()> held = [state] {
      std::array<char,1> src{'x'}; std::array<char,2> dst{};
      state->all_gather(src.data(),dst.data(),src.size());
    };
    auto second = held; state.reset(); require(p.released == 0);
    held(); held = {}; require(p.released == 0); second = {}; require(p.released == 1); ++checks;
  }
  {
    Probe p; auto state = make(p); state->bind(0,2);
    auto work = [state] {
      std::array<char,1> src{'a'}; std::array<char,2> dst{};
      state->all_gather(src.data(),dst.data(),src.size());
    };
    std::thread a(work), b(work); a.join(); b.join();
    require(p.calls == 2 && p.sequences == std::vector<uint64_t>({0,1})); ++checks;
  }
  std::cout << "{\"passed\":true,\"checks\":" << checks
            << ",\"actualBridgeState\":true,\"nativeJACCLOrNetworkExecution\":false}\n";
}
