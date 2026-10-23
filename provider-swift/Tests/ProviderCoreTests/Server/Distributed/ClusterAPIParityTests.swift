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

    /// Multi-token transport must not lose or reorder captured values even
    /// though the asynchronous channel may partition them across SSE frames.
    /// This is a completeness check, not a per-content-frame association claim.
    @Test(arguments: ParityFamily.all.map(\.name))
    func streamedLogprobsRetainEveryCapturedValue(_ name: String) async throws {
        let family = try #require(ParityFamily.all.first { $0.name == name })
        let directory = try family.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizer = family.tokenizer
        let stops = EngineV2Translation.stopTokenIds(
            eosTokenIds: ModelEOSPolicy.effectiveEOSTokenIds(
                modelId: family.modelID, modelType: family.modelType, base: try family.loaderEOS(directory),
                tokenToId: { tokenizer.convertTokenToId($0) }),
            tokenizerEOSTokenId: tokenizer.eosTokenId, extraEOSTokens: [],
            convertTokenToId: { tokenizer.convertTokenToId($0) })
        var committed: [Int] = []
        for token in family.plain { committed.append(token); if stops.contains(token) { break } }
        let expected: [[String: Any]] = committed.map { token in
            let text = tokenizer.decode(tokenIds: [token], skipSpecialTokens: false)
            return ["token": text, "logprob": -0.25, "bytes": Array(text.utf8), "top_logprobs": [
                ["token": text, "logprob": -0.25, "bytes": Array(text.utf8)],
                ["token": "", "logprob": -2.0, "bytes": [UInt8]()]]]
        }
        let encode: ([[String: Any]]) throws -> Data = {
            try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        }
        for answer in try await parityCapturedStream(family) {
            #expect(answer.status == 200)
            #expect(answer.body.last == "data: [DONE]")
            var entries: [[String: Any]] = []
            for frame in answer.body where frame.hasPrefix("data: ") && frame != "data: [DONE]" {
                let object = try #require(JSONSerialization.jsonObject(
                    with: Data(frame.dropFirst(6).utf8)) as? [String: Any])
                for choice in object["choices"] as? [[String: Any]] ?? [] {
                    if let logprobs = choice["logprobs"] as? [String: Any] {
                        entries += try #require(logprobs["content"] as? [[String: Any]])
                    }
                }
            }
            #expect(try encode(entries) == encode(expected), "\(name): capture lost or reordered values")
        }
    }

    /// The comparable fixture above explicitly supplies captured values. A
    /// real selected mode without capture support must refuse before reserve,
    /// then remain available for ordinary text. Neither test qualifies a GPU.
    @Test func unsupportedLogprobsRefuseWithoutPoisoningTheEndpoint() async throws {
        let family = try #require(ParityFamily.all.first)
        let directory = try family.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cluster = try await ParityClusterServer.start(
            family: family, directory: directory, supportsLogprobs: false)
        let client = URLSession(configuration: .ephemeral)
        do {
            for stream in [false, true] {
                let request = ParityCase("unsupported-logprobs", body: ParityCase.chat(
                    family.modelID, #","logprobs":true,"top_logprobs":2"#, stream: stream))
                let answer = try await paritySend(port: cluster.port, request, session: client)
                #expect(answer.status == 400)
                #expect(answer.body.contains { $0.contains("logprob_capture_unsupported") })
                #expect(cluster.session.base.reserveCount == 0)
            }
            let stop = ParityStopFlag()
            let driver = Task { await cluster.drive(after: 0, script: family.plain, failure: false, stop: stop) }
            do {
                let answer = try await paritySend(port: cluster.port,
                    .init("plain", body: ParityCase.chat(family.modelID)), session: client)
                #expect(answer.status == 200)
                #expect(cluster.session.base.reserveCount == 1)
            } catch { stop.set(); await driver.value; throw error }
            stop.set(); await driver.value
        } catch {
            client.invalidateAndCancel(); await cluster.stop(); throw error
        }
        client.invalidateAndCancel(); await cluster.stop()
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

    /// The coordinator path (a leader member's pair slot, served by the same
    /// inference handler as a single-Mac slot) reads the model's directory:
    /// its stop set and sampling defaults are a single-Mac slot's.
    @Test func thePairSlotServesWithTheSingleMacSlotsStopSetAndSamplingDefaults() async throws {
        for family in ParityFamily.all where ["gpt-oss-20b", "nemotron-3.5", "qwen3.5-9b"].contains(family.name) {
            let directory = try family.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let tokenizer = family.tokenizer
            let loop = try await clusterPairMemberLoop(models: [family.modelID], modelType: family.modelType)
            let owner = ScriptedPairOwner()
            let specification = ClusterPairSlotSpecification(publicModelID: family.modelID, modelType: family.modelType,
                tokenizer: TokenizerHandle(tokenizer), eosTokenIDs: try family.installedEOS(),
                expectedIdentity: owner.identity, profile: try distributedTestProfile(), artifactBytes: 1 << 30,
                modelDirectory: directory)
            _ = try await loop.publishClusterPairSlot(specification, owner: owner)
            let bridge = try #require(await loop.modelSlots[family.modelID]?.engineV2)
            let expected = EngineV2Translation.stopTokenIds(
                eosTokenIds: ModelEOSPolicy.effectiveEOSTokenIds(
                    modelId: family.modelID, modelType: family.modelType, base: try family.loaderEOS(directory),
                    tokenToId: { tokenizer.convertTokenToId($0) }),
                tokenizerEOSTokenId: tokenizer.eosTokenId, extraEOSTokens: [],
                convertTokenToId: { tokenizer.convertTokenToId($0) })
            let stops = await bridge.stopTokenIds, defaults = await bridge.samplingDefaults
            #expect(stops == expected, "\(family.name): pair slot \(stops.sorted()) single-Mac \(expected.sorted())")
            #expect(defaults == EngineV2SamplingDefaults.resolve(
                modelId: family.modelID, modelType: family.modelType, modelDirectory: directory), "\(family.name)")
            #expect(await loop.retireClusterPairSlot(reason: "test"))
        }
    }
}
