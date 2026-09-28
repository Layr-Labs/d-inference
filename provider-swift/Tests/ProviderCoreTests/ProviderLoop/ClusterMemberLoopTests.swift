import Foundation
import Testing
@testable import ProviderCore

private final class MemberMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OutboundMessage] = []
    func append(_ value: OutboundMessage) { lock.withLock { values.append(value) } }
    var snapshot: [OutboundMessage] { lock.withLock { values } }
}
private func makeMemberLoop(endpoint: LocalInferenceHTTPConfig? = nil, stopOnDisconnect: Bool = false) throws -> ProviderLoop {
    let hardware = HardwareInfo(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4, chipTier: .pro,
        memoryGb: 24, memoryAvailableGb: 20, cpuCores: .init(total: 12, performance: 8, efficiency: 4),
        gpuCores: 16, memoryBandwidthGbs: 200)
    return try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused", hardware: hardware,
        models: [.init(id: "fixture-member-model", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)],
        config: ProviderConfig(provider: .init(name: "member-test", memoryReserveGB: 1),
            backend: .init(idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: .init(heartbeatIntervalSecs: 60)),
        localEndpoint: endpoint, executionRole: .clusterMember, clusterMemberStopsOnDisconnect: stopOnDisconnect),
        purgeLegacyFiles: false, attestationSigner: nil)
}

@Suite("Cluster member control loop")
struct ClusterMemberLoopTests {
    @Test func directLoadPrefetchInferenceAndDesiredEventsNeverStartWork() async throws {
        let loop = try makeMemberLoop()
        let recorder = MemberMessages(), send = SendHandle { recorder.append($0) }
        await loop.handleLoadModelRequest(modelId: "fixture-member-model", send: send)
        await loop.handlePrefetchModelRequest(modelId: "fixture-member-model", priority: 1, send: send)
        // Invalid encrypted bytes must never reach decryption/admission here.
        await loop.handleInferenceRequest(requestId: "rejected", ciphertext: Data([1]), senderPublicKey: nil,
            cacheReceiptNonce: nil, authenticatedCacheScope: nil, send: send)
        #expect(await loop.consumeClusterMemberEvent(.desiredModels(entries: []), send: send))
        do { try await loop.ensureModelLoaded(modelId: "fixture-member-model"); Issue.record("member loaded model") }
        catch { #expect(error is ClusterMemberControlError) }
        let messages = recorder.snapshot
        #expect(messages.count == 3)
        if case .loadModelStatus(_, .failed, _) = messages[0] {} else { Issue.record("load started") }
        if case .prefetchModelStatus(_, .failed, 0, 0, _) = messages[1] {} else { Issue.record("prefetch started") }
        if case .inferenceError(_, let failure, _) = messages[2] { #expect(failure.code == .modelUnavailable) }
        else { Issue.record("inference accepted") }
        #expect(await loop.memberWorkIsEmpty())
    }

    @Test func emptyCapacityAndNoPersistenceOrBackgroundLoad() async throws {
        let loop = try makeMemberLoop()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        await loop.memberTestStateFile(path)
        try await loop.prepareClusterMemberControl()
        let state = await loop.state
        #expect(state.backendCapacity?.slots.isEmpty == true)
        #expect(state.backendCapacity?.freeForLoadGb == 0 && state.refusingNewWork)
        #expect(await loop.memberWorkIsEmpty())
        #expect(await loop.loadedModelsPersistenceEnabled == false)
        let incompatible = try makeMemberLoop(endpoint: .init(host: "127.0.0.1", port: 0, authToken: nil))
        do { try await incompatible.prepareClusterMemberControl(); Issue.record("member accepted solo endpoint") }
        catch { #expect(error is ClusterMemberControlError) }
    }

    @Test func disconnectDropsConnectionGenerationBeforeReconnect() async throws {
        let loop = try makeMemberLoop(), send = SendHandle { _ in }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        await loop.memberTestStateFile(path)
        _ = await loop.consumeClusterMemberEvent(.connected, send: send)
        let first = try #require(await loop.memberConnectionID)
        _ = await loop.consumeClusterMemberEvent(.disconnected, send: send)
        #expect(await loop.memberConnectionID == nil)
        _ = await loop.consumeClusterMemberEvent(.connected, send: send)
        #expect(await loop.memberConnectionID != first)
    }

    @Test func acceptedLeaderControlLossLatchesStopBeforeReconnect() async throws {
        let loop = try makeMemberLoop(stopOnDisconnect: true), send = SendHandle { _ in }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        await loop.memberTestStateFile(path)
        _ = await loop.consumeClusterMemberEvent(.disconnected, send: send)
        #expect(await loop.memberControlRequiresStop == false)
        _ = await loop.consumeClusterMemberEvent(.connected, send: send)
        #expect(await loop.memberConnectionID != nil)
        _ = await loop.consumeClusterMemberEvent(.disconnected, send: send)
        #expect(await loop.memberControlRequiresStop)
        #expect(await loop.memberConnectionID == nil)
        _ = await loop.consumeClusterMemberEvent(.connected, send: send)
        #expect(await loop.memberConnectionID == nil)
    }

    @Test func unacknowledgedAndCancelledRegistrationWaitsRefuse() async throws {
        let loop = try makeMemberLoop()
        do {
            try await loop.waitForClusterMemberRegistration(until: .now)
            Issue.record("expired wait succeeded")
        } catch { #expect(error is ClusterMemberControlError) }
        let task = Task { try await loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(30))) }
        task.cancel()
        do { try await task.value; Issue.record("cancelled wait succeeded") } catch { #expect(error is CancellationError) }
        #expect(await loop.memberRegistrationWaiter == nil)
    }
}

private extension ProviderLoop {
    func memberTestStateFile(_ url: URL) { daemonStateFileOverride = url }
    func memberWorkIsEmpty() -> Bool {
        modelSlots.isEmpty && modelsLoading.isEmpty && preloadTasks.isEmpty &&
        prefetchCoordinator == nil && startupPreloadTask == nil && mtpUpgradeMonitorTask == nil &&
        capacityRefreshTask == nil && inflightProfiles.isEmpty
    }
}
