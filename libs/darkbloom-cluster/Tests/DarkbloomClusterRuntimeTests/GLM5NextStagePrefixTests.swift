import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// GLM's prompt-prefix state on constructed layer caches: what a capture
/// keeps restores bit for bit, a shallower frontier views a prefix of the
/// deepest DSA copy, and a history the tiers cannot rebuild is not kept.
struct GLM5NextStagePrefixTests {
    private static let latentWidth = 6, indexWidth = 4

    private func dsa(tokens: Int, seed: Float, valid: Bool = true) -> GLM5NextDSACache {
        let cache = GLM5NextDSACache()
        let base = MLXArray(0..<Int32(tokens)).asType(.float32).reshaped([1, tokens, 1]) + MLXArray(seed)
        var validity = MLXArray.ones([1, tokens], dtype: .bool)
        if !valid { validity = MLXArray([true] + Array(repeating: false, count: tokens - 1)).reshaped([1, tokens]) }
        cache.state = [broadcast(base, to: [1, tokens, Self.latentWidth]),
                       broadcast(base * 2, to: [1, tokens, Self.indexWidth]),
                       broadcast(base * 3, to: [1, tokens, Self.indexWidth]), validity]
        return cache
    }

    private func kda(tokens: Int, seed: Float) -> GLM5NextKDACache {
        let cache = GLM5NextKDACache()
        cache.state = [MLXArray.ones([1, 3, 8]) * MLXArray(seed), MLXArray.ones([1, 2, 4, 4], dtype: .float32) * MLXArray(seed + 1)]
        cache.metaState = ["glm5_kda_v1", String(tokens)]
        return cache
    }

    private func same(_ a: MLXArray, _ b: MLXArray) -> Bool {
        a.shape == b.shape && a.dtype == b.dtype && arrayEqual(a, b).item(Bool.self)
    }

    @Test func captureRestoresEveryLayerBitForBit() throws {
        let layers: [any KVCache] = [kda(tokens: 5, seed: 1), dsa(tokens: 5, seed: 10)]
        let state = try #require(try GLM5NextStagePrefixSnapshot.capture(layers: layers, globalLayers: [7, 8], frontier: 5))
        #expect(state.dsa[8]?.keys.shape == [1, 1, 5, Self.latentWidth])
        #expect(state.dsa[8]?.values.shape == [1, 1, 5, 2 * Self.indexWidth])
        let kept = QwenStagePrefixState(committedTokens: 5, attention: state.dsa, recurrent: state.kda)
        let fresh: [any KVCache] = [GLM5NextKDACache(), GLM5NextDSACache()]
        try GLM5NextStagePrefixSnapshot.restore(kept, into: fresh, globalLayers: [7, 8])
        #expect(fresh.allSatisfy { $0.offset == 5 })
        for (original, restored) in zip(layers, fresh) {
            #expect(original.state.count == restored.state.count)
            for (a, b) in zip(original.state, restored.state) { #expect(same(a, b)) }
        }
    }

    @Test func shallowerFrontierViewsThePrefixOfTheDeepestCopy() throws {
        let capture = ClusterStagePrefixCapture.glm5Next(frontiers: [3, 5])
        try capture.capture(at: 3, caches: [kda(tokens: 3, seed: 1), dsa(tokens: 3, seed: 10)], globalLayers: [0, 1])
        let deepest: [any KVCache] = [kda(tokens: 5, seed: 2), dsa(tokens: 5, seed: 10)]
        try capture.capture(at: 5, caches: deepest, globalLayers: [0, 1])
        let states = capture.states()
        #expect(states.map(\.committedTokens) == [3, 5])
        let shallow = try #require(states.first), deep = try #require(states.last)
        #expect(shallow.attention[1]?.keys.dim(2) == 3)
        #expect(same(shallow.attention[1]!.keys, deep.attention[1]!.keys[0..., 0..., 0..<3, 0...]))
        // Each frontier keeps its own KDA state.
        #expect(!same(shallow.recurrent[0]!.ssm, deep.recurrent[0]!.ssm))
        #expect(capture.sharedBytes == deep.attention[1]!.keys.nbytes + deep.attention[1]!.values.nbytes)
        let fresh: [any KVCache] = [GLM5NextKDACache(), GLM5NextDSACache()]
        try GLM5NextStagePrefixSnapshot.restore(shallow, into: fresh, globalLayers: [0, 1])
        #expect(fresh.allSatisfy { $0.offset == 3 })
    }

    @Test func invalidPositionIsNotKeptAndForeignLayersAreRefused() throws {
        #expect(try GLM5NextStagePrefixSnapshot.capture(layers: [dsa(tokens: 4, seed: 0, valid: false)],
                                                        globalLayers: [2], frontier: 4) == nil)
        let state = try #require(try GLM5NextStagePrefixSnapshot.capture(layers: [dsa(tokens: 4, seed: 0)],
                                                                          globalLayers: [2], frontier: 4))
        let kept = QwenStagePrefixState(committedTokens: 4, attention: state.dsa, recurrent: state.kda)
        // A state of another layer, or a cache that is not fresh, restores nothing.
        #expect(throws: (any Error).self) {
            try GLM5NextStagePrefixSnapshot.restore(kept, into: [GLM5NextDSACache()], globalLayers: [3])
        }
        #expect(throws: (any Error).self) {
            try GLM5NextStagePrefixSnapshot.restore(kept, into: [dsa(tokens: 1, seed: 0)], globalLayers: [2])
        }
    }

    /// A kept state of the wrong shape or type restores nothing: the request
    /// prefills from zero and the refused layer is left as fresh as it came.
    @Test func malformedKeptStateIsRefusedAndLeavesTheLayerFresh() throws {
        let conv = MLXArray.ones([1, 3, 8]), ssm = MLXArray.ones([1, 2, 4, 4], dtype: .float32)
        let rows = MLXArray.ones([1, 1, 4, Self.latentWidth])
        let refused: [(QwenStagePrefixState, any KVCache)] = [
            // A KDA convolution or recurrent state of the wrong rank.
            (QwenStagePrefixState(committedTokens: 4, attention: [:], recurrent: [0: (conv: conv.squeezed(axis: 0), ssm: ssm)]),
             GLM5NextKDACache()),
            (QwenStagePrefixState(committedTokens: 4, attention: [:], recurrent: [0: (conv: conv, ssm: ssm.squeezed(axis: 0))]),
             GLM5NextKDACache()),
            // A KDA recurrent state that is not float32.
            (QwenStagePrefixState(committedTokens: 4, attention: [:], recurrent: [0: (conv: conv, ssm: ssm.asType(.float16))]),
             GLM5NextKDACache()),
            // DSA index keys and pool gates must split the packed values evenly.
            (QwenStagePrefixState(committedTokens: 4, attention: [0: (keys: rows, values: MLXArray.ones([1, 1, 4, 7]))],
                                  recurrent: [:]), GLM5NextDSACache()),
        ]
        for (state, layer) in refused {
            #expect(throws: (any Error).self) {
                try GLM5NextStagePrefixSnapshot.restore(state, into: [layer], globalLayers: [0])
            }
            #expect(layer.offset == 0 && layer.innerState().isEmpty)
        }
        // The same states, well formed, restore.
        try GLM5NextStagePrefixSnapshot.restore(QwenStagePrefixState(committedTokens: 4, attention: [:],
            recurrent: [0: (conv: conv, ssm: ssm)]), into: [GLM5NextKDACache()], globalLayers: [0])
        try GLM5NextStagePrefixSnapshot.restore(QwenStagePrefixState(committedTokens: 4,
            attention: [0: (keys: rows, values: MLXArray.ones([1, 1, 4, 8]))], recurrent: [:]),
            into: [GLM5NextDSACache()], globalLayers: [0])
    }

    /// The encrypted SSD record keeps GLM's packed DSA rows and KDA state as
    /// it keeps attention and recurrent state: a new process restores every
    /// kept frontier into fresh caches bit for bit.
    @Test func theEncryptedSSDRecordRestoresEveryKeptFrontierBitForBit() throws {
        let capture = ClusterStagePrefixCapture.glm5Next(frontiers: [2, 4])
        let shallow: [any KVCache] = [kda(tokens: 2, seed: 1), dsa(tokens: 2, seed: 10)]
        let deep: [any KVCache] = [kda(tokens: 4, seed: 3), dsa(tokens: 4, seed: 10)]
        try capture.capture(at: 2, caches: shallow, globalLayers: [0, 1])
        try capture.capture(at: 4, caches: deep, globalLayers: [0, 1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glm-prefix-ssd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = QwenStagePrefixDiskConfiguration(mode: .on(root: root, key: Data(repeating: 7, count: 32)))
        configuration.strideTokens = 2; configuration.minimumTokens = 1; configuration.minimumFreeBytes = 1
        let tokens = [4, 5, 6, 7, 8], scope = "glm-scope|chunk=2"
        let written = try #require(QwenStagePrefixDiskTier.open(configuration: configuration, planScope: "glm-plan", rank: 0))
        written.persist(scope: scope, tokens: tokens, states: capture.states(), blockTokens: 2)
        #expect(written.drain(timeoutSeconds: 20))
        written.close()
        let tier = try #require(QwenStagePrefixDiskTier.open(configuration: configuration, planScope: "glm-plan", rank: 0))
        defer { tier.close() }
        #expect(tier.frontiers(scope: scope, tokens: tokens, maximumFrontier: tokens.count - 1) == [4, 2])
        for (frontier, original) in [(2, shallow), (4, deep)] {
            let state = try #require(try tier.restore(scope: scope, tokens: tokens, frontier: frontier, check: {}))
            let fresh: [any KVCache] = [GLM5NextKDACache(), GLM5NextDSACache()]
            try GLM5NextStagePrefixSnapshot.restore(state, into: fresh, globalLayers: [0, 1])
            for (a, b) in zip(original, fresh) {
                for (x, y) in zip(a.state, b.state) { #expect(same(x, y), "SSD frontier \(frontier)") }
            }
        }
    }
}
