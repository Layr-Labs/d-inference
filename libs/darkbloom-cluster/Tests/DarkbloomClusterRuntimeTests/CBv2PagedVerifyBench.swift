import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

// Diagnosis benchmark, off unless DARKBLOOM_PAGED_BENCH=1: attention-only cost of a
// speculative verify window (and of prompt chunks) on paged vs contiguous rows at a long
// context, in the 9B's attention geometry (16 query heads, 4 KV heads, head dim 256, bf16).
// Random K/V, no model. It prints timings; it asserts nothing about speed.
@Suite("Paged verify/prefill attention bench (diagnosis, env-gated)", .serialized)
struct CBv2PagedVerifyBench {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["DARKBLOOM_PAGED_BENCH"] == "1"
    static let context = Int(environment["DARKBLOOM_PAGED_BENCH_CTX"] ?? "") ?? 30_720
    static let layers = Int(environment["DARKBLOOM_PAGED_BENCH_LAYERS"] ?? "") ?? 4
    static let width = Int(environment["DARKBLOOM_PAGED_BENCH_WIDTH"] ?? "") ?? 5
    static let chunk = 512
    static let kinds = (0..<layers).map {
        CBv2LayerKind(attention: .full, headDim: 256, kvHeads: 4, queryHeads: 16, modelLayerIndex: $0)
    }

    static func rand(_ shape: [Int]) -> MLXArray { (MLXRandom.normal(shape) * 0.5).asType(.bfloat16) }

    static func run(paged: Bool) throws -> (prefill: Double, window: Double) {
        let maxLength = context + 256
        let caches: [any CBv2AttendingLayerCache]
        let backend: any CBv2KVBackend
        if paged {
            let b = try PagedKVBackend(layerKinds: kinds, config: PagedKVPoolConfig(
                capacityBytes: (maxLength + 64) * 4 * 256 * 2 * 2 * layers + (64 << 20), dtype: .bfloat16,
                maxPrefillChunk: chunk, nominalMaxSequenceLength: maxLength,
                maxBufferLength: GPU.deviceInfo().maxBufferSize, segmentSizeBytes: 64 << 20,
                layerDTypes: Array(repeating: .bfloat16, count: layers)), slabCommitment: .atFirstAdmission)
            let made = b.makeLayerCaches()
            for cache in made { cache.prefillMirrorAllowed = environment["DARKBLOOM_PAGED_BENCH_MIRROR"] != "0" }
            caches = made; backend = b
        } else {
            backend = CBv2ContiguousKVBackend(config: .init(
                bytesCapacity: (maxLength + 512) * 4 * 256 * 2 * 2 * layers, kvDType: .bfloat16))
            caches = kinds.enumerated().map { CBv2LayerCache(layerIndex: $0.offset, kind: $0.element) }
        }
        let bank = CBv2LayerCacheBank(caches: caches)
        let rows = try backend.makeSequenceState(layerKinds: kinds, promptLength: context, maxLength: maxLength)
        _ = bank.layerCaches(rowStates: [rows])
        let scale = Float(1.0 / sqrt(256.0))
        // Prompt chunks (timed as a whole).
        let start = Date()
        var offset = 0
        while offset < context {
            let n = min(chunk, context - offset)
            var roots: [MLXArray] = []
            for cache in caches {
                roots.append(cache.updateAndAttend(queries: rand([1, 16, n, 256]), keys: rand([1, 4, n, 256]),
                    values: rand([1, 4, n, 256]), scale: scale, sinks: nil))
                roots += (cache as! any KVCache).innerState()
            }
            eval(roots)
            offset += n
        }
        let prefill = Date().timeIntervalSince(start)
        // One plain decode step leaves the prompt (drops any mirror).
        var roots: [MLXArray] = []
        for cache in caches {
            roots.append(cache.updateAndAttend(queries: rand([1, 16, 1, 256]), keys: rand([1, 4, 1, 256]),
                values: rand([1, 4, 1, 256]), scale: scale, sinks: nil))
            roots += (cache as! any KVCache).innerState()
        }
        eval(roots)
        // Verify windows: width columns, keep 2, roll the rest back (as the stage does).
        let q = rand([1, 16, width, 256]), k = rand([1, 4, width, 256]), v = rand([1, 4, width, 256])
        eval(q, k, v)
        var windowTime = 0.0
        let rounds = 40
        for round in 0..<(rounds + 5) {
            let t0 = Date()
            var outs: [MLXArray] = []
            let body = {
                for cache in caches {
                    outs.append(cache.updateAndAttend(queries: q, keys: k, values: v, scale: scale, sinks: nil))
                    outs += (cache as! any KVCache).innerState()
                }
            }
            if paged { bank.withMTPRectangularVerification(batched: true, body) } else { body() }
            eval(outs)
            for row in rows { row?.rollback(width - 2) }
            bank.invalidateBoundComposition()
            _ = bank.layerCaches(rowStates: [rows])
            eval(caches.map(\.positionOffsets))
            if round >= 5 { windowTime += Date().timeIntervalSince(t0) }
        }
        bank.releaseBoundRows()
        backend.release(rows)
        return (prefill, windowTime / Double(rounds))
    }

    @Test(.enabled(if: enabled)) func verifyAndPrefillAttention() throws {
        for paged in [true, false, true, false] {
            let r = try Self.run(paged: paged)
            print("darkbloom-paged-bench \(paged ? "paged" : "contiguous") ctx=\(Self.context) layers=\(Self.layers)"
                + " width=\(Self.width) prefill_s=\(String(format: "%.3f", r.prefill))"
                + " window_ms=\(String(format: "%.3f", r.window * 1000))"
                + " mq=\(ProcessInfo.processInfo.environment["DARKBLOOM_PAGED_MTP_MULTI_QUERY"] ?? "default")")
        }
    }
}
