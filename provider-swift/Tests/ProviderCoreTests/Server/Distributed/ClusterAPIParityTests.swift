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

    /// A stream the shared pipeline rejects mid-generation (a named tool
    /// choice answered with text, `toolChoiceViolation`) ends on a cluster with
    /// the single-Mac endpoint's own failure frame, also while the pair is
    /// still finishing the cancelled request: here the pair acknowledges
    /// retirement only once the client has the whole answer, as a pair still
    /// finishing a step does. The run above acknowledges at once, so it met
    /// this order only intermittently (`tool-choice-named-stream`).
    @Test(arguments: ["qwen3.8-27b", "qwen3.5-9b", "qwen3.5-35b-a3b", "bonsai-27b", "nemotron-3.5"])
    func streamRejectedMidGenerationEndsWithTheSingleMacFailureFrameBeforeRetirement(_ name: String) async throws {
        let family = try #require(ParityFamily.all.first { $0.name == name })
        let testCase = try #require(ParityCase.all(family).first { $0.name == "tool-choice-named-stream" })
        let tokens = testCase.script.tokens(family)
        let directory = try family.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = ParityScript()
        script.set(tokens)
        let solo = try await ParitySoloServer.start(family: family, directory: directory, script: script)
        let cluster = try await ParityClusterServer.start(family: family, directory: directory)
        let client = URLSession(configuration: .ephemeral)
        do {
            let single = try await paritySend(port: solo.port, testCase, session: client)
            try #require(single.status == 200 && single.body.last?.contains(#""finish_reason":"error""#) == true,
                         "\(name): the fixture no longer fails on a single Mac")
            let owner = cluster.session.base
            let bridge = try #require(await cluster.host.entry?.engineV2Bridge)
            let retirement = LocalHostLatch(), stop = ParityStopFlag()
            let driver = Task {
                await cluster.drive(after: 0, script: tokens, failure: false, stop: stop, retirement: retirement)
            }
            let pair: ParityAnswer
            do {
                pair = try await paritySend(port: cluster.port, testCase, session: client)
                // Answered while the pair still owns the request. The pipeline
                // cancelled it (this lease takes no clean stop) and gave back its
                // acquisition and HTTP hold; only its lane waits for retirement.
                #expect(try await httpDeliveryEventually { owner.lease(0).cancelCount == 1 })
                #expect(try await localHostEventually { await cluster.host.responses.activeResponseCount == 0 })
                #expect(await cluster.host.pins.isEmpty)
                #expect(owner.lease(0).releaseCount == 0)
                #expect(await bridge.activeRequestCount() == 1)
            } catch { retirement.complete(); stop.set(); await driver.value; throw error }
            retirement.complete(); stop.set(); await driver.value
            #expect(pair == single, "\(name):\n single-Mac: \(single)\n cluster:    \(pair)")
            // Retirement releases the lease and frees the lane.
            #expect(try await httpDeliveryEventually { owner.lease(0).releaseCount == 1 })
            #expect(try await localHostEventually { await bridge.activeRequestCount() == 0 })
        } catch {
            client.invalidateAndCancel(); await cluster.stop(); await solo.stop(); throw error
        }
        client.invalidateAndCancel(); await cluster.stop(); await solo.stop()
    }

    /// Every captured value in this three-token visible script must survive,
    /// in order, on both JSON and SSE paths. It ends by length, without an EOS
    /// or parser-only token whose metadata has no visible attachment boundary.
    @Test(arguments: ParityFamily.all.map(\.name))
    func capturedResponsesRetainEveryVisibleTokenValue(_ name: String) async throws {
        let family = try #require(ParityFamily.all.first { $0.name == name })
        let tokens = ParityScriptKind.capturedContent.tokens(family)
        for stream in [false, true] {
            for answer in try await parityCapturedResponses(family, contentOnly: true, stream: stream) {
                #expect(answer.status == 200)
                if stream { #expect(answer.body.last == "data: [DONE]") }
                #expect(try capturedEntries(answer) == expectedEntries(tokens, family: family),
                        "\(name), stream=\(stream): capture lost or reordered visible values")
            }
        }
    }

    /// Preserve the original mixed reasoning/EOS exercise. Collected JSON owns
    /// the complete capture; streaming must never move a trailing non-content
    /// EOS backward onto an earlier answer. Reasoning source-span classification
    /// remains a separate limitation; entries before visible content stay ordered.
    @Test(arguments: ParityFamily.all.map(\.name))
    func trailingStopMetadataCannotMoveBackwardIntoStreamedContent(_ name: String) async throws {
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
        var contentBound: [Int] = []
        var trailingStop: Int?
        for token in family.plain {
            if stops.contains(token) { trailingStop = token; break }
            contentBound.append(token)
        }
        let stop = try #require(trailingStop)
        for stream in [false, true] {
            let expected = stream ? contentBound : contentBound + [stop]
            for answer in try await parityCapturedResponses(family, contentOnly: false, stream: stream) {
                #expect(answer.status == 200)
                if stream { #expect(answer.body.last == "data: [DONE]") }
                #expect(try capturedEntries(answer) == expectedEntries(expected, family: family),
                        "\(name), stream=\(stream): captured ordering or trailing-stop boundary changed")
            }
        }
    }

    private func expectedEntries(_ tokens: [Int], family: ParityFamily) throws -> Data {
        let entries: [[String: Any]] = tokens.map { token in
            let text = family.tokenizer.decode(tokenIds: [token], skipSpecialTokens: false)
            return ["token": text, "logprob": -0.25, "bytes": Array(text.utf8), "top_logprobs": [
                ["token": text, "logprob": -0.25, "bytes": Array(text.utf8)],
                ["token": "", "logprob": -2.0, "bytes": [UInt8]()]]]
        }
        return try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
    }

    private func capturedEntries(_ answer: ParityAnswer) throws -> Data {
        var entries: [[String: Any]] = []
        for frame in answer.body where frame != "data: [DONE]" {
            let text = frame.hasPrefix("data: ") ? String(frame.dropFirst(6)) : frame
            let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            for choice in object["choices"] as? [[String: Any]] ?? [] {
                if let logprobs = choice["logprobs"] as? [String: Any] {
                    entries += try #require(logprobs["content"] as? [[String: Any]])
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
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
