import Foundation

/// One thread per rank, created for one test: `run` hands every rank's thread
/// the same body and returns when all of them have finished.
///
/// MLX keys a compiled function's traces (`compile`, MLXNN's `silu`, the Qwen
/// 3.5 decode fusions) by the calling thread's default stream on the core's
/// default device, the GPU, whatever device the Swift task-local scope names.
/// A worker thread that `DispatchQueue.concurrentPerform` reuses can hold
/// traces an earlier GPU test recorded: a CPU-mode rank then replays them and
/// runs those operations on the GPU, and its bytes differ from the other rank's
/// and from its own earlier frames (with `MLX_DISABLE_COMPILE=1` they do not).
/// Threads of the test's own have default streams no other test has used.
final class TensorParallelRankThreads: @unchecked Sendable {
    private final class Shared: @unchecked Sendable {
        let condition = NSCondition()
        var body: ((Int) -> Void)?
        var round = 0, running = 0, stopped = false
    }

    private let shared = Shared()
    let count: Int

    init(count: Int = 2) {
        self.count = count
        for rank in 0..<count {
            let shared = self.shared
            let thread = Thread {
                var served = 0
                while true {
                    shared.condition.lock()
                    while !shared.stopped && shared.round == served { shared.condition.wait() }
                    guard !shared.stopped, let body = shared.body else { shared.condition.unlock(); return }
                    served = shared.round
                    shared.condition.unlock()
                    body(rank)
                    shared.condition.lock()
                    shared.running -= 1
                    if shared.running == 0 { shared.condition.broadcast() }
                    shared.condition.unlock()
                }
            }
            thread.stackSize = 8 << 20
            thread.start()
        }
    }

    func run(_ body: @escaping (Int) -> Void) {
        shared.condition.lock()
        defer { shared.condition.unlock() }
        shared.body = body
        shared.running = count
        shared.round += 1
        shared.condition.broadcast()
        while shared.running > 0 { shared.condition.wait() }
        shared.body = nil
    }

    deinit {
        shared.condition.lock()
        shared.stopped = true
        shared.condition.broadcast()
        shared.condition.unlock()
    }
}
