import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// The cluster's API answers every request exactly as the single-Mac API
/// does (owner rule 2026-10-14 13:55): the same request set, the same
/// committed tokens, compared byte for byte minus ids and timestamps; and
/// the same request reaches the engine (stop set, sampling, limits).
/// Model-free (`ClusterAPIParityHarness.swift`); not a hardware result.
@Suite(.timeLimit(.minutes(3)))
struct ClusterAPIParityTests {
    @Test(arguments: ParityFamily.all.map(\.name))
    func clusterAnswersEveryRequestAsTheSingleMacEndpoint(_ name: String) async throws {
        let family = try #require(ParityFamily.all.first { $0.name == name })
        let mismatches = try await parityRun(family)
        parityRecord(mismatches, family: family.name)
        #expect(mismatches.isEmpty, "\(mismatches.count) differences:\n\(mismatches.joined(separator: "\n\n"))")
    }

    /// GPT-OSS ends a tool call with `<|call|>`: the single-Mac slot stops
    /// there (its generation config and the Harmony EOS policy), so the
    /// call is answered with `finish_reason: tool_calls` and nothing after.
    @Test func clusterStopsWhereTheSingleMacSlotStops() async throws {
        for family in ParityFamily.all {
            let directory = try family.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let tokenizer = family.tokenizer
            let expected = EngineV2Translation.stopTokenIds(
                eosTokenIds: ModelEOSPolicy.effectiveEOSTokenIds(
                    modelId: family.modelID, modelType: family.modelType, base: try family.loaderEOS(directory),
                    tokenToId: { tokenizer.convertTokenToId($0) }),
                tokenizerEOSTokenId: tokenizer.eosTokenId, extraEOSTokens: [],
                convertTokenToId: { tokenizer.convertTokenToId($0) })
            let session = try ParityClusterSession(family: family, directory: directory)
            let entry = try DistributedEngineFactory.makeRegistryEntry(
                owner: session.base, expectedIdentity: session.base.identity, publicModelID: family.modelID,
                profile: session.profile, tokenizer: TokenizerHandle(tokenizer),
                eosTokenIDs: try session.model.stopTokenIDs(tokenizerEOS: tokenizer.eosTokenId),
                modelType: family.modelType, modelDirectory: directory)
            let bridge = try #require(entry.engineV2Bridge)
            let stops = await bridge.stopTokenIds, defaults = await bridge.samplingDefaults
            #expect(stops == expected, "\(family.name): cluster \(stops.sorted()) single-Mac \(expected.sorted())")
            #expect(defaults == EngineV2SamplingDefaults.resolve(
                modelId: family.modelID, modelType: family.modelType, modelDirectory: directory), "\(family.name)")
            await bridge.shutdown()
        }
    }
}
