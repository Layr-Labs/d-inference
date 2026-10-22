import Foundation
import MLX
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// What a GLM tensor-parallel prefix entry holds: the buffers it keeps alive
/// are what it counts, its DSA histories carry no spare columns, and a
/// restored entry continues exactly as the cache it was stored from. Tiny
/// synthetic arrays and stage; no model and no pair.
@Suite("GLM tensor-parallel prefix cache memory", .serialized)
struct GLM5NextTensorParallelPrefixCacheTests {
    typealias Cache = GLM5NextTensorParallelPrefixCache

    static func fence(_ arrays: [MLXArray]) throws {
        try MLX.withError { error in
            eval(arrays); Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
        }
    }

    static func bytes(_ array: MLXArray) -> Data { array.asData(access: .copy).data }

    @Test func aViewCountsTheWholeBufferItKeepsAlive() throws {
        let whole = MLXArray(Array(repeating: Float(1), count: 1 << 16))
        let view = whole[..<16]
        try Self.fence([whole, view])
        #expect(view.nbytes == 64)
        #expect(Cache.bufferBytes([view]) >= whole.nbytes)
        #expect(Cache.bufferBytes([view, view]) >= 2 * whole.nbytes)
    }

    /// A history whose storage has far more columns than it uses (geometric
    /// growth) is copied down to its logical columns, bit for bit; one
    /// without spare columns keeps its buffers.
    @Test func compactingADSAHistoryDropsItsSpareColumnsAndKeepsItsValues() throws {
        let capacity = 4096, used = 100
        func storage(_ width: Int, salt: Float) -> MLXArray {
            MLXArray((0 ..< capacity * width).map { Float($0 % 97) * 0.5 - salt }, [1, capacity, width])
        }
        let latents = storage(8, salt: 3), keys = storage(4, salt: 1), gates = storage(4, salt: 2)
        let validity = MLXArray((0 ..< capacity).map { $0 % 3 != 0 }, [1, capacity])
        let history = GLM5NextDSACache()
        history.state = [latents[0..., ..<used], keys[0..., ..<used], gates[0..., ..<used], validity[0..., ..<used]]
        let before = history.state
        try Self.fence(before)
        let spare = Cache.bufferBytes(before)
        #expect(spare >= latents.nbytes + keys.nbytes + gates.nbytes + validity.nbytes)

        Cache.compact(history)
        let after = history.state
        try Self.fence(after)
        #expect(history.offset == used)
        #expect(after.map(\.shape) == before.map(\.shape))
        #expect(zip(after, before).allSatisfy { Self.bytes($0) == Self.bytes($1) })
        let logical = after.reduce(0) { $0 + $1.nbytes }
        let exact = Cache.bufferBytes(after)
        #expect(exact >= logical && exact <= logical + 4 * 16_384)
        #expect(exact * 10 < spare)

        // Already exact: compacting shares the buffers again (no copy).
        let again = history.state
        Cache.compact(history)
        try Self.fence(history.state)
        #expect(Cache.bufferBytes(history.state) == Cache.bufferBytes(again))
    }

    /// Store, restore, one more step: the restored entry gives the same
    /// output bits and the same history as the live cache it came from, and
    /// the entry's count is the bytes it holds.
    @Test func aRestoredEntryContinuesExactlyAsTheLiveCache() throws {
        defer {
            do { try MLX.withError { error in Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check() } }
            catch { Issue.record(error, "GLM prefix fixture cleanup fence failed") }
        }
        let artifact = try GLM5NextStageSessionTests.Artifact()
        let loader = try artifact.loader()
        let c = loader.configuration.textConfig
        let stage = try loader.loadTextStage(plan: .init(configuration: c, layers: 0..<4))
        func step(_ tokens: [Int32], _ cache: GLM5NextTextStageCache) throws -> [MLXArray] {
            let output = try stage.prepareForward(tokens: MLXArray(tokens, [1, tokens.count]), cache: cache)
                .commit { arrays in try Self.fence(arrays) }
            guard case .streams(let streams) = output else { throw ProbeError("tiny first stage returned no streams") }
            return [streams]
        }
        let live = stage.newCache()
        _ = try step([4, 5], live)
        _ = try step([6], live) // DSA grows from 2 columns to its 256-column backing.
        let prompt = [4, 5, 6, 7, 8]
        let prefix = Cache(budgetBytes: 1 << 30)
        prefix.store(scope: "scope", prompt: prompt, length: 3, cache: live)
        #expect(prefix.count == 1)
        let restored = try #require(prefix.restore(scope: "scope", prompt: prompt, length: 3))
        #expect(restored.cache.offset == live.offset)
        let held = restored.cache.layers.flatMap { $0.innerState() }
        try Self.fence(held)
        #expect(prefix.bytesInUse == Cache.bufferBytes(held))
        #expect(prefix.bytesInUse >= held.reduce(0) { $0 + $1.nbytes })
        // Another prompt under another scope is not found.
        #expect(prefix.restore(scope: "other", prompt: prompt, length: 3) == nil)

        let continued = live.copy()
        let fromLive = try step([7, 8], continued)
        let fromEntry = try step([7, 8], restored.cache)
        #expect(zip(fromLive, fromEntry).allSatisfy { Self.bytes($0) == Self.bytes($1) })
        #expect(continued.offset == 5 && restored.cache.offset == 5)
        for (a, b) in zip(continued.layers, restored.cache.layers) {
            let (x, y) = (a.state, b.state)
            try Self.fence(x + y)
            #expect(x.count == y.count && zip(x, y).allSatisfy { Self.bytes($0) == Self.bytes($1) })
        }
        #expect(prefix.sweep() > 0 && prefix.count == 0 && prefix.bytesInUse == 0)
    }

    /// A refusal gives the freed-buffer cache back before any entry, and
    /// entries only when that was not enough.
    @Test func refusalsYieldTheFreedBufferCacheFirst() throws {
        let prefix = Cache(budgetBytes: 1 << 20)
        var attempts = 0
        // Something in MLX's freed-buffer cache: one released buffer.
        do { let scratch = MLXArray.zeros([1 << 16]); try Self.fence([scratch]) }
        #expect(Memory.cacheMemory > 0)
        let value = try prefix.yieldingMemory { () throws -> Int in
            attempts += 1
            if attempts == 1 { throw ProbeError("refused") }
            return attempts
        }
        #expect(value == 2 && Memory.cacheMemory == 0)
        // Nothing left to give: the refusal stands.
        attempts = 0
        #expect(throws: ProbeError.self) {
            try prefix.yieldingMemory { () throws -> Int in attempts += 1; throw ProbeError("refused") }
        }
        #expect(attempts == 1)
    }
}
