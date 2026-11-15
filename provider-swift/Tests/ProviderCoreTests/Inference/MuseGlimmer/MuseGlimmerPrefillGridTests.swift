// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// Muse Glimmer's prompt grid: the SDK cuts every prompt of the model at
/// multiples of `prefillChunkAlignment` (1,024 tokens), so the paged pool's
/// prompt write must hold whole cells. Every provider knob that sizes it either
/// keeps it on the grid or refuses the load with a typed reason.
@Suite("Muse Glimmer prefill grid", .serialized)
struct MuseGlimmerPrefillGridTests {
    static let stripeKey = EngineV2Factory.soloPrefillStripeKey
    static let chunkKey = EngineV2Factory.prefillChunkKey
    static let stepKey = EngineV2Factory.stepTokenBudgetKey

    private func prepare(
        _ model: any LanguageModel, modelID: String? = MuseGlimmerDrafterTests.modelID,
        _ environment: [String: String] = [:]
    ) throws -> EngineV2Factory.ProductionBackendPreparation {
        try EngineV2Factory.prepareProductionBackend(
            model: model, modelID: modelID, kvBytesCapacity: 64 << 20, maxConcurrentRequests: 1,
            kvBackend: .auto, maxContextLength: 2048,
            environment: environment.merging([KVBackendGuardStore.pathEnvKey: "/dev/null"]) { $1 })
    }

    private func poolPrefillChunk(
        _ prepared: EngineV2Factory.ProductionBackendPreparation, _ model: any LanguageModel
    ) throws -> Int? {
        let (backend, _) = try prepared.consume(model: model, maxConcurrentRequests: 1)
        return (backend as? PagedKVBackend)?.pool.config.maxPrefillChunk
    }

    private func engine(_ target: MuseGlimmerTextModel, _ environment: [String: String]) throws -> EngineV2 {
        let engine = try EngineV2Factory.makeProductionEngine(
            model: target, modelID: MuseGlimmerDrafterTests.modelID, tokenizer: GlimmerDrafterTokenizer(),
            kvBytesCapacity: 64 << 20, maxConcurrentRequests: 1, mtpDrafter: nil, mtpConfig: CBv2MTPConfig(),
            kvBackend: .paged, maxContextLength: 4096,
            environment: environment.merging([KVBackendGuardStore.pathEnvKey: "/dev/null"]) { $1 })
        return try #require(engine as? EngineV2)
    }

    private func tokens(_ engine: EngineV2, _ request: CBv2Request) async throws -> [Int] {
        var tokens: [Int] = []
        for await event in try engine.submit(request) {
            if case .delta(_, let emitted, _) = event { tokens += emitted }
        }
        return tokens
    }

    @Test("the tower reports the SDK's grid, and the default pool writes exactly one cell")
    func defaultGrid() async throws {
        let tower = try MuseGlimmerDrafterTests.exactTower()
        let alignment = try #require(tower.cbv2Capabilities.prefillChunkAlignment)
        #expect(alignment == MuseGlimmerTextModel.defaultPrefillChunkAlignment)
        #expect(EngineV2Factory.museGlimmerSoloPrefillStripeTokens == alignment)
        let prepared = try prepare(tower)
        #expect(prepared.modelCapabilities.prefillChunkAlignment == alignment)
        #expect(EngineV2Factory.pagedPrefillChunkTokens(prepared.schedulerConfig) == alignment)
        #expect(try poolPrefillChunk(prepared, tower) == alignment)
        // The engine the slot serves cuts on the same grid.
        let served = try engine(tower, [:])
        #expect(served.modelCapabilities.prefillChunkAlignment == alignment)
        await served.shutdown()
    }

    @Test("a chunk or stripe setting that leaves the pool off the grid refuses the load")
    func offGridRefuses() throws {
        let tower = try MuseGlimmerDrafterTests.exactTower()
        let refused: [[String: String]] = [
            [Self.stripeKey: "0"],  // striping off: the pool falls to the 512-token chunk
            [Self.stripeKey: "not-a-number"],
            [Self.stripeKey: "512"],  // not above the chunk, so striping is off
            [Self.stripeKey: "1536"],  // above one cell, off the grid
            [Self.chunkKey: "1500"],  // the default stripe no longer arms above it
            [Self.chunkKey: "3000"],
        ]
        for environment in refused {
            do {
                _ = try prepare(tower, environment)
                Issue.record("loaded off the grid with \(environment)")
            } catch EngineV2ProductionError.prefillGridUnfit(let alignment, let chunk) {
                #expect(alignment == 1024)
                #expect(chunk < alignment || chunk % alignment != 0, "\(environment)")
                let message = String(describing: EngineV2ProductionError.prefillGridUnfit(
                    alignment: alignment, pagedPrefillChunk: chunk))
                #expect(message.contains("1024-token cells") && message.contains(Self.stripeKey))
            }
        }
    }

    @Test("settings that keep whole cells load, and other models ignore the grid rule")
    func onGridLoads() throws {
        let tower = try MuseGlimmerDrafterTests.exactTower()
        let served: [[String: String]: Int] = [
            [:]: 1024,
            [Self.stripeKey: "2048"]: 2048,
            [Self.chunkKey: "2048"]: 2048,
            [Self.chunkKey: "100"]: 1024,  // the default stripe arms above a small chunk
            [Self.stepKey: "600"]: 1024,  // a step budget below one cell: a step still carries one
        ]
        for (environment, chunk) in served {
            let prepared = try prepare(tower, environment)
            #expect(try poolPrefillChunk(prepared, tower) == chunk, "\(environment)")
        }
        // The same off-grid stripe leaves another model's load as it was.
        let other = try MuseGlimmerDrafterTests.otherModel()
        let prepared = try prepare(other, modelID: nil, [Self.stripeKey: "0"])
        #expect(prepared.modelCapabilities.prefillChunkAlignment == nil)
    }

    @Test("a step budget below one cell serves the same tokens as the default")
    func narrowStepBudgetKeepsTokens() async throws {
        let tower = try MuseGlimmerDrafterTests.exactTower()
        // Two whole cells and a remainder.
        let prompt = (0 ..< 2_300).map { ($0 * 11 + 5) % 90 }
        let request = CBv2Request(
            id: .init(1), promptTokens: prompt, sampling: CBv2SamplingParams(temperature: 0), maxTokens: 12)
        let wide = try engine(tower, [:])
        let expected = try await tokens(wide, request)
        await wide.shutdown()
        let narrow = try engine(tower, [Self.stepKey: "600"])
        let actual = try await tokens(narrow, request)
        await narrow.shutdown()
        #expect(expected.count == 12 && actual == expected)
    }
}
