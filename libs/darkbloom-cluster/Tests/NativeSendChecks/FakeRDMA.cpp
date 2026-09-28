#include <optional>
#include <utility>
#include "FakeRDMA.h"

namespace {
std::vector<char> bytes(const ibv_sge& entry) {
  const auto* pointer = reinterpret_cast<const char*>(entry.addr);
  return {pointer, pointer + entry.length};
}
void checkUnchanged(const fixture::Pending& pending) {
  fixture::require(bytes(pending.entry) == pending.original,
      "Send buffer reused before its completion was polled");
}
} // namespace

namespace jaccl {
// Allocation/registration only are fake. The candidate's actual SharedBuffer
// staging/SGE methods and actual Connection post/poll methods remain in use.
SharedBuffer::SharedBuffer(size_t count) : data_(nullptr), num_bytes_(count) {
  if (posix_memalign(&data_, 4096, count) != 0) { throw std::bad_alloc(); }
  std::memset(data_, fixture::sentinel, count);
}
SharedBuffer::SharedBuffer(SharedBuffer&& other) : data_(nullptr), num_bytes_(0) {
  std::swap(data_, other.data_); std::swap(num_bytes_, other.num_bytes_);
  memory_regions_.swap(other.memory_regions_);
}
SharedBuffer::~SharedBuffer() {
  for (const auto& entry : memory_regions_) { delete entry.second; }
  std::free(data_);
}
void SharedBuffer::register_to_protection_domain(ibv_pd* domain) {
  if (!memory_regions_.contains(domain)) { memory_regions_[domain] = new ibv_mr{1}; }
}
Connection::Connection(ibv_context* context)
    : ctx(context), protection_domain(nullptr), completion_queue(nullptr),
      queue_pair(nullptr), src{} {}
Connection::Connection(Connection&& other) : Connection(nullptr) {
  std::swap(ctx, other.ctx); std::swap(protection_domain, other.protection_domain);
  std::swap(completion_queue, other.completion_queue);
  std::swap(queue_pair, other.queue_pair); std::swap(src, other.src);
}
Connection::~Connection() {
  delete ctx; delete protection_domain; delete completion_queue; delete queue_pair;
}
} // namespace jaccl

namespace fixture {
void Fabric::pair(jaccl::Connection& a, jaccl::Connection& b, int wire, int side) {
  auto first = std::make_unique<Endpoint>();
  auto second = std::make_unique<Endpoint>();
  first->fabric = second->fabric = this;
  first->rank = 0; second->rank = 1;
  first->side = side; second->side = 1 - side;
  first->wire = second->wire = wire;
  first->peer = second.get(); second->peer = first.get();
  auto attach = [](jaccl::Connection& connection, Endpoint* endpoint) {
    connection.ctx = new ibv_context{};
    connection.protection_domain = new ibv_pd{};
    connection.completion_queue = new ibv_cq{endpoint};
    connection.queue_pair = new ibv_qp{endpoint};
  };
  attach(a, first.get()); attach(b, second.get());
  endpoints.push_back(std::move(first)); endpoints.push_back(std::move(second));
}
void Fabric::match(Endpoint& sender) {
  auto& receiver = *sender.peer;
  while (!sender.sends.empty() && !receiver.receives.empty()) {
    auto send = std::move(sender.sends.front()); sender.sends.pop_front();
    auto receive = std::move(receiver.receives.front()); receiver.receives.pop_front();
    checkUnchanged(send);
    require(send.entry.length == receive.entry.length,
        "Fixed native send/receive SGE lengths changed");
    std::memcpy(reinterpret_cast<void*>(receive.entry.addr),
        reinterpret_cast<const void*>(send.entry.addr), send.entry.length);
    frames.push_back({sender.rank, sender.side, sender.wire, send.original});
    sender.completions.push_back({{send.id, send.entry.length}, std::move(send)});
    receiver.completions.push_back({{receive.id, receive.entry.length}, std::nullopt});
  }
  changed.notify_all();
}
void Fabric::requireDrained() {
  std::lock_guard lock(mutex);
  for (const auto& endpoint : endpoints) {
    require(endpoint->sends.empty() && endpoint->receives.empty()
        && endpoint->completions.empty(), "Native request/completion remains owned");
  }
}
} // namespace fixture

int ibv_post_send(ibv_qp* qp, ibv_send_wr* wr, ibv_send_wr**) {
  fixture::require(wr->num_sge == 1 && wr->next == nullptr
      && wr->opcode == IBV_WR_SEND && wr->send_flags == IBV_SEND_SIGNALED,
      "Native send WQE changed");
  auto& endpoint = *static_cast<fixture::Endpoint*>(qp->fixture);
  std::lock_guard lock(endpoint.fabric->mutex);
  endpoint.sends.push_back({wr->sg_list[0], wr->wr_id, bytes(wr->sg_list[0])});
  endpoint.fabric->match(endpoint);
  return 0;
}
int ibv_post_recv(ibv_qp* qp, ibv_recv_wr* wr, ibv_recv_wr**) {
  fixture::require(wr->num_sge == 1 && wr->next == nullptr, "Native receive WQE changed");
  auto& endpoint = *static_cast<fixture::Endpoint*>(qp->fixture);
  std::lock_guard lock(endpoint.fabric->mutex);
  endpoint.receives.push_back({wr->sg_list[0], wr->wr_id, {}});
  endpoint.fabric->match(*endpoint.peer);
  return 0;
}
int ibv_poll_cq(ibv_cq* cq, int maximum, ibv_wc* out) {
  auto& endpoint = *static_cast<fixture::Endpoint*>(cq->fixture);
  std::unique_lock lock(endpoint.fabric->mutex);
  fixture::require(std::chrono::steady_clock::now() < endpoint.fabric->deadline,
      "Fake native completion deadline");
  if (endpoint.completions.empty()) {
    endpoint.fabric->changed.wait_for(lock, std::chrono::milliseconds(1));
  }
  int count = 0;
  while (count < maximum && !endpoint.completions.empty()) {
    auto completion = std::move(endpoint.completions.front()); endpoint.completions.pop_front();
    if (completion.send) { checkUnchanged(*completion.send); }
    out[count++] = completion.value;
  }
  return count;
}
