import Foundation
import MLX

/// Both ranks of a Gemma 4 tensor-parallel pair in one process: each rank's
/// shard runs on its own thread and MLX stream, and every collective is the
/// elementwise FP32 sum of both ranks' partials, added in rank order (the
/// add of two values is commutative, so it is the sum a two-rank all-sum
/// returns). Every rank-local operation keeps the rank's own shapes and
/// kernels, so a two-process run over a real collective must equal it bit
/// for bit: the oracle for the transport, its sealing and the collective
/// schedule. Each collective evaluates its inputs, so this is an oracle, not
/// a timing.
public final class Gemma4TensorParallelLocalPair: @unchecked Sendable {
    private let condition = NSCondition()
    private var leaving = 0, step = 0
    private var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
    private var output: [Float] = []
    /// Every collective's payload shape, in order.
    public private(set) var payloads: [[Int]] = []

    public init() {}

    /// Rank `rank`'s reduction.
    public func reduction(rank: Int) -> QwenTensorParallelReduction { Rank(rank: rank, pair: self) }

    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2
        let pair: Gemma4TensorParallelLocalPair
        init(rank: Int, pair: Gemma4TensorParallelLocalPair) { self.rank = rank; self.pair = pair }
        func allSum(_ value: MLXArray) -> MLXArray { pair.sum(value, rank: rank) }
    }

    func sum(_ value: MLXArray, rank: Int) -> MLXArray {
        precondition(value.dtype == .float32, "Gemma tensor-parallel collectives carry FP32")
        let mine = value.asArray(Float.self)
        condition.lock()
        defer { condition.unlock() }
        while leaving > 0 { condition.wait() }
        let generation = step
        precondition(values[rank] == nil, "rank \(rank) entered a collective twice")
        values[rank] = mine
        shapes[rank] = value.shape
        if values.count == 2 {
            precondition(shapes[0] == shapes[1], "the ranks' collectives differ in shape")
            output = zip(values[0]!, values[1]!).map(+)
            payloads.append(shapes[0]!)
            leaving = 2
            condition.broadcast()
        } else {
            let deadline = Date().addingTimeInterval(600)
            while leaving == 0 && step == generation {
                precondition(condition.wait(until: deadline), "the other rank never reached the collective")
            }
        }
        let result = output
        leaving -= 1
        if leaving == 0 {
            values = [:]; shapes = [:]; output = []; step += 1
            condition.broadcast()
        }
        return MLXArray(result, value.shape)
    }

    /// Runs `body(rank)` for both ranks at once, each on a thread of its own
    /// with its own default stream on `device` (MLX's default stream is
    /// process-wide and not thread-safe); returns both results in rank order.
    public static func run<T>(device: Device, _ body: @escaping @Sendable (Int) throws -> T) throws -> [T] {
        let results = PairResults<T>()
        let done = DispatchGroup()
        for rank in 0 ..< 2 {
            done.enter()
            let thread = Thread {
                let result = Device.withDefaultDevice(device) {
                    Stream.withNewDefaultStream(device: device) { Result { try body(rank) } }
                }
                results.lock.lock(); results.values[rank] = result; results.lock.unlock()
                done.leave()
            }
            thread.stackSize = 8 << 20
            thread.start()
        }
        done.wait()
        return try results.values.map { try $0!.get() }
    }
}

private final class PairResults<T>: @unchecked Sendable {
    var values: [Result<T, Error>?] = [nil, nil]
    let lock = NSLock()
}
