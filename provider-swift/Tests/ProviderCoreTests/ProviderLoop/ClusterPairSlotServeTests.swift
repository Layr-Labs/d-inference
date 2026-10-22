import Foundation
import Testing
@testable import ProviderCore

/// A member loop's `run()` against a `MockCoordinator` on a loopback port,
/// serving the coordinator's encrypted `inference_request` through its pair
/// slot. The execution owner is scripted, so this proves the provider path
/// (registration, heartbeats, routing, encryption, terminals), not a pair.
private struct PairServeFixture {
    let mock: MockCoordinator
    let loop: ProviderLoop
    let directory: URL

    static func make(modelType: String) async throws -> PairServeFixture {
        let mock = MockCoordinator()
        let url = try await mock.start().mockProviderWebSocketURL()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cluster-pair-serve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 64, memoryAvailableGb: 64, cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(
            config: .init(coordinatorURL: url, hardware: hardware,
                models: [.init(id: clusterPairFixtureModel, modelType: modelType, sizeBytes: 1, estimatedMemoryGb: 1)],
                config: .init(provider: .init(name: "cluster-pair-serve", autoUpdate: false), backend: .init(),
                    coordinator: .init(url: url, heartbeatIntervalSecs: 1)),
                executionRole: .clusterMember),
            attestationSigner: ServeLoopTestSigner())
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.setServeUsesHostServicesForTesting(false)
        await loop.setDaemonStateFileForTesting(directory.appendingPathComponent("state.json"))
        // The production warmup canary (S18) runs before admission opens.
        await loop.setClusterPairWarmupForTesting(timeoutSeconds: 30)
        return .init(mock: mock, loop: loop, directory: directory)
    }

    func cleanUp(_ task: Task<Void, Error>) async {
        task.cancel()
        _ = await ServeLoopFixture.finishes(task, within: .seconds(30))
        await mock.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func push(_ id: String, publicKey: String, consumer: NodeKeyPair, model: String = clusterPairFixtureModel) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "pair"]],
            "max_tokens": 3, "stream": true, "temperature": 0, "reasoning_parser": "none"])
        try await mock.pushInferenceRequest(requestId: id, providerPublicKeyBase64: publicKey,
            chatRequestJSON: body, consumerKeyPair: consumer)
    }
}

@Suite("Cluster pair slot serves coordinator traffic", .serialized, .timeLimit(.minutes(2)))
struct ClusterPairSlotServeTests {
    @Test("Leader member serves an encrypted request through its pair slot", arguments: ["qwen3_5", "mimo_v2"])
    func leaderServesAnEncryptedRequestThroughItsPairSlot(modelType: String) async throws {
        let fixture = try await PairServeFixture.make(modelType: modelType)
        let task = Task { try await fixture.loop.run() }
        do {
            let registration = try #require(try await fixture.mock.awaitFirstRegister(timeout: .seconds(15)))
            try await fixture.mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
            try await fixture.loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(5)))
            let publicKey = try #require(registration.publicKey)
            // No pair yet: the member drains, holds no slot and refuses.
            try await fixture.push("before-pair", publicKey: publicKey, consumer: .generate())
            let early = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) {
                $0.inferenceErrors.contains { $0.requestId == "before-pair" } }?.inferenceErrors.first)
            #expect(early.statusCode == 503 && early.failureCode == .modelUnavailable)

            let owner = ScriptedPairOwner()
            try await fixture.loop.publishClusterPairSlot(
                clusterPairSpecification(owner, modelType: modelType), owner: owner)
            // C14: one loaded slot and not draining.
            let serving = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { snapshot in
                snapshot.heartbeats.contains { $0.status == .idle && $0.backendCapacity?.slots.count == 1 } })
            let beat = try #require(serving.heartbeats.last { $0.status == .idle })
            #expect(beat.backendCapacity?.slots.first?.model == clusterPairFixtureModel)
            #expect(beat.backendCapacity?.slots.first?.state == "idle")
            #expect(beat.warmModels == [clusterPairFixtureModel])

            let consumer = NodeKeyPair.generate()
            try await fixture.push("pair-1", publicKey: publicKey, consumer: consumer)
            let done = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
                $0.inferenceComplete.contains { $0.requestId == "pair-1" }
                    || $0.inferenceErrors.contains { $0.requestId == "pair-1" } })
            #expect(done.inferenceErrors.filter { $0.requestId == "pair-1" }.isEmpty,
                    "errors: \(done.inferenceErrors.map { "\($0.requestId) \($0.statusCode)" })")
            #expect(done.inferenceAccepted.contains { $0.requestId == "pair-1" })
            var text = ""
            for chunk in done.inferenceChunks where chunk.requestId == "pair-1" {
                let sealed = try #require(chunk.encryptedData)
                #expect(chunk.data.isEmpty)
                text += String(decoding: try consumer.decryptPayload(sealed), as: UTF8.self)
            }
            #expect(text.contains("t5") && text.contains("t6") && text.contains("t7"), "stream: \(text)")
            let complete = try #require(done.inferenceComplete.first { $0.requestId == "pair-1" })
            #expect(complete.usage.completionTokens == 3)
            // The warmup canary's reservation, then this request's.
            #expect(await fixture.loop.clusterPairWarmup?.succeeded == true)
            #expect(owner.reserveCount == 2)

            // Another model is not this member's: refused, never reserved.
            try await fixture.push("other-model", publicKey: publicKey, consumer: .generate(), model: "fixture/other")
            let other = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) {
                $0.inferenceErrors.contains { $0.requestId == "other-model" } }?.inferenceErrors.first { $0.requestId == "other-model" })
            #expect(other.statusCode == 503 && owner.reserveCount == 2)

            // A lost rank retires the slot: draining with no slot again.
            owner.losePeer()
            #expect(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { snapshot in
                guard let last = snapshot.heartbeats.last else { return false }
                return last.status == .draining && last.backendCapacity?.slots.isEmpty == true } != nil)
            try await fixture.push("after-loss", publicKey: publicKey, consumer: .generate())
            let after = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) {
                $0.inferenceErrors.contains { $0.requestId == "after-loss" } }?.inferenceErrors.first { $0.requestId == "after-loss" })
            #expect(after.statusCode == 503 && after.failureCode == .modelUnavailable)
            #expect(owner.shutdownCount == 1 && owner.reserveCount == 2)
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }

    @Test func stoppingTheMemberRetiresItsSlotAndShutsThePairDown() async throws {
        let fixture = try await PairServeFixture.make(modelType: "qwen3_5")
        let task = Task { try await fixture.loop.run() }
        do {
            let registration = try #require(try await fixture.mock.awaitFirstRegister(timeout: .seconds(15)))
            try await fixture.mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
            try await fixture.loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(5)))
            let owner = ScriptedPairOwner()
            try await fixture.loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
            task.cancel()
            #expect(await ServeLoopFixture.finishes(task, within: .seconds(30)))
            #expect(owner.shutdownCount == 1)
            #expect(await fixture.loop.clusterPairSlotSnapshot.slots.isEmpty)
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }
}
