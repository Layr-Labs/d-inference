import Foundation
import MLX
import MLXNN

/// Process-local, main-thread, warmup-only counters. No MLX array is retained.
/// The benchmark removes the observer before entering any measured request.
@_spi(ClusterBenchmark)
public struct QwenGatedDeltaWarmupObservation: Encodable {
    public let nativePrefillCalls: Int
    public let nativeDecodeCalls: Int
    public let operationsFallbackCalls: Int
    public let invalidGeometryCalls: Int
}

final class QwenGatedDeltaWarmupCounter {
    var prefill = 0, decode = 0, fallback = 0, invalid = 0
    func record(native: Bool, tokenCount: Int, batch: Int, keyHeads: Int,
                valueHeads: Int, keyDim: Int, valueDim: Int, bf16: Bool, stateFP32: Bool) {
        guard Thread.isMainThread, batch == 1, keyHeads == 16, valueHeads == 32,
              keyDim == 128, valueDim == 128, bf16, stateFP32,
              tokenCount == 1 || tokenCount == 512 else { invalid += 1; return }
        if !native { fallback += 1 }
        else if tokenCount == 512 { prefill += 1 }
        else { decode += 1 }
    }
    var observation: QwenGatedDeltaWarmupObservation {
        .init(nativePrefillCalls: prefill, nativeDecodeCalls: decode,
              operationsFallbackCalls: fallback, invalidGeometryCalls: invalid)
    }
}

// The private benchmark owns the only synchronous model executor on main.
// Other users leave this nil. No lock/array copy/counter work occurs when nil.
nonisolated(unsafe) var qwenGatedDeltaWarmupCounter: QwenGatedDeltaWarmupCounter?

@_spi(ClusterBenchmark)
public func withQwenGatedDeltaWarmupObservation<T>(_ body: () throws -> T) throws
    -> (T, QwenGatedDeltaWarmupObservation) {
    guard Thread.isMainThread, qwenGatedDeltaWarmupCounter == nil else {
        throw NSError(domain: "QwenResidentBenchmark", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Warmup observation requires one main-thread owner"])
    }
    let counter = QwenGatedDeltaWarmupCounter()
    qwenGatedDeltaWarmupCounter = counter
    defer { qwenGatedDeltaWarmupCounter = nil }
    let result = try body()
    return (result, counter.observation)
}

@_spi(ClusterBenchmark)
public func qwen35BenchmarkFusedProjectionCounts(_ model: Module) -> (gatedDeltaLayers: Int, fusedLayers: Int) {
    let layers = model.namedModules().compactMap { $0.1 as? Qwen35GatedDeltaNet }
    return (layers.count, layers.filter(\.hasFusedInputProjection).count)
}
