import Foundation
import Testing
@testable import ProviderCore

@Suite("Coordinator-authorized update lifecycle")
struct UpdateLifecycleTests {
    @Test("frozen lifecycle transitions are exact and monotonic")
    func allTransitions() throws {
        var reconciler = try UpdateLifecycleReconciler()
        _ = try reconciler.authorize(
            command(generation: 1), currentVersion: "1.0.0", warmIntents: [])
        let expected: [UpdateLifecycleState] = [
            .drainingForUpdate, .installing, .reconnecting,
            .applicationVerifying, .modelReloading, .ready,
        ]
        for state in expected {
            try reconciler.transition(to: state)
            #expect(reconciler.record.state == state)
        }
        #expect(UpdateLifecycleState.allCases.map(\.rawValue) == [
            "serving", "draining_for_update", "installing", "reconnecting",
            "application_verifying", "model_reloading", "ready", "blocked",
        ])
    }

    @Test("out-of-order transitions and blocked retries fail closed")
    func outOfOrderAndBlocked() throws {
        var reconciler = try UpdateLifecycleReconciler()
        _ = try reconciler.authorize(
            command(generation: 4), currentVersion: "1.0.0", warmIntents: [])
        #expect(throws: UpdateLifecycleError.self) {
            try reconciler.transition(to: .installing)
        }
        reconciler.block()
        #expect(reconciler.record.state == .blocked)
        #expect(throws: UpdateLifecycleError.self) {
            try reconciler.transition(to: .drainingForUpdate)
        }
        #expect(throws: UpdateLifecycleError.self) {
            _ = try reconciler.authorize(
                command(generation: 4), currentVersion: "1.0.0", warmIntents: [])
            try reconciler.transition(to: .drainingForUpdate)
        }
        #expect(try reconciler.authorize(
            command(version: "3.0.0", generation: 5),
            currentVersion: "1.0.0",
            warmIntents: []))
        #expect(reconciler.record.state == .serving)
    }

    @Test("stale and equal-conflicting generations are rejected")
    func staleAndConflictingGenerations() throws {
        var reconciler = try UpdateLifecycleReconciler()
        let accepted = command(generation: 9)
        _ = try reconciler.authorize(
            accepted, currentVersion: "1.0.0", warmIntents: [])
        #expect(try !reconciler.authorize(
            accepted, currentVersion: "1.0.0", warmIntents: []))
        #expect(throws: UpdateLifecycleError.self) {
            _ = try reconciler.authorize(
                command(version: "3.0.0", generation: 9),
                currentVersion: "1.0.0",
                warmIntents: [])
        }
        #expect(throws: UpdateLifecycleError.self) {
            _ = try reconciler.authorize(
                command(generation: 8), currentVersion: "1.0.0", warmIntents: [])
        }
    }

    @Test("same target cannot be relabeled or revived under a new generation")
    func stableGenerationPerTarget() throws {
        var active = try UpdateLifecycleReconciler()
        _ = try active.authorize(
            command(generation: 10),
            currentVersion: "1.0.0",
            warmIntents: [
                intent(model: "model-a", slot: "slot-a", generation: 10)
            ])
        try active.transition(to: .drainingForUpdate)
        try active.transition(to: .installing)

        #expect(try !active.authorize(
            command(generation: 10),
            currentVersion: "1.0.0",
            warmIntents: []))
        #expect(throws: UpdateLifecycleError.self) {
            _ = try active.authorize(
                command(generation: 11),
                currentVersion: "1.0.0",
                warmIntents: [])
        }
        #expect(active.record.state == .installing)
        #expect(active.record.command?.desiredGeneration == 10)
        #expect(active.record.warmIntents.first?.desiredGeneration == 10)

        var ready = try UpdateLifecycleReconciler(record: UpdateLifecycleRecord(
            state: .ready,
            command: command(generation: 10)))
        #expect(throws: UpdateLifecycleError.self) {
            _ = try ready.authorize(
                command(generation: 11),
                currentVersion: "2.0.0",
                warmIntents: [])
        }
        #expect(ready.record.state == .ready)
        #expect(ready.record.command?.desiredGeneration == 10)

        var blocked = try UpdateLifecycleReconciler(record: UpdateLifecycleRecord(
            state: .blocked,
            command: command(generation: 10)))
        #expect(throws: UpdateLifecycleError.self) {
            _ = try blocked.authorize(
                command(generation: 11),
                currentVersion: "1.0.0",
                warmIntents: [])
        }
        #expect(blocked.record.state == .blocked)
        #expect(blocked.record.command?.desiredGeneration == 10)

        var reconnecting = try UpdateLifecycleReconciler(
            record: UpdateLifecycleRecord(
                state: .reconnecting,
                command: command(generation: 10),
                warmIntents: [
                    intent(model: "model-a", slot: "slot-a", generation: 10)
                ]))
        #expect(try !reconnecting.authorize(
            command(generation: 10),
            currentVersion: "1.0.0",
            warmIntents: []))
        #expect(reconnecting.record.state == .reconnecting)
        #expect(reconnecting.record.warmIntents.first?.desiredGeneration == 10)
    }

    @Test("semantic-version downgrade is refused")
    func downgradeRefusal() throws {
        var reconciler = try UpdateLifecycleReconciler()
        #expect(throws: UpdateLifecycleError.self) {
            _ = try reconciler.authorize(
                command(version: "1.9.9", generation: 1),
                currentVersion: "2.0.0",
                warmIntents: [])
        }
        #expect(reconciler.record.command == nil)
        #expect(reconciler.record.state == .serving)
    }

    @Test("crash-safe store resumes every durable intermediate state")
    func crashResumeStates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UpdateLifecycleStore(file: root.appendingPathComponent("state.json"))
        let update = command(generation: 17)
        let states: [UpdateLifecycleState] = [
            .drainingForUpdate, .installing, .reconnecting,
            .applicationVerifying, .modelReloading, .ready, .blocked,
        ]
        for state in states {
            let record = UpdateLifecycleRecord(
                state: state,
                command: update,
                warmIntents: state == .ready ? [] : [
                    intent(model: "model-a", slot: "slot-a", generation: 17)
                ])
            try store.save(record)
            #expect(try store.load() == record)
        }
    }

    @Test("warm intent is ordered and carries exact KV, MTP, hash, and generation")
    func orderedWarmIntent() throws {
        var reconciler = try UpdateLifecycleReconciler()
        _ = try reconciler.authorize(
            command(generation: 23),
            currentVersion: "1.0.0",
            warmIntents: [
                intent(model: "model-b", slot: "slot-2", generation: 99),
                intent(model: "model-a", slot: "slot-1", generation: 99),
            ])
        let ordered = reconciler.record.warmIntents
        #expect(ordered.map(\.modelId) == ["model-a", "model-b"])
        #expect(ordered[0].modelHash == "hash-model-a")
        #expect(ordered[0].slotId == "slot-1")
        #expect(ordered[0].kvBackend == "paged")
        #expect(ordered[0].kvQuantization == "fp16")
        #expect(ordered[0].mtpModelId == "mtp-model-a")
        #expect(ordered[0].desiredGeneration == 23)

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ordered[0]))
                as? [String: Any])
        #expect(object["model_id"] as? String == "model-a")
        #expect(object["model_hash"] as? String == "hash-model-a")
        #expect(object["slot_id"] as? String == "slot-1")
        #expect(object["kv_backend"] as? String == "paged")
        #expect(object["kv_quantization"] as? String == "fp16")
        #expect(object["mtp_model_id"] as? String == "mtp-model-a")
        #expect(object["desired_generation"] as? Int == 23)
    }

    @Test("ready requires new application-proof stage and completed model reload")
    func readyOnlyAfterProofAndReload() throws {
        let warm = intent(model: "model-a", slot: "slot-a", generation: 31)
        var reconciler = try UpdateLifecycleReconciler()
        _ = try reconciler.authorize(
            command(generation: 31), currentVersion: "1.0.0", warmIntents: [warm])
        try reconciler.transition(to: .drainingForUpdate)
        try reconciler.transition(to: .installing)
        try reconciler.transition(to: .reconnecting)
        #expect(throws: UpdateLifecycleError.self) {
            try reconciler.transition(to: .modelReloading)
        }
        try reconciler.transition(to: .applicationVerifying)
        try reconciler.transition(to: .modelReloading)
        #expect(throws: UpdateLifecycleError.self) {
            try reconciler.transition(to: .ready)
        }
        let normalized = try #require(reconciler.record.reportedWarmIntent)
        try reconciler.completeNextWarmIntent(normalized)
        try reconciler.transition(to: .ready)
        #expect(reconciler.record.state == .ready)
        let terminalIntent = try #require(reconciler.record.reportedWarmIntent)
        #expect(terminalIntent.desiredGeneration == 31)
        #expect(terminalIntent.modelId == nil)

        var zeroWarm = try UpdateLifecycleReconciler()
        _ = try zeroWarm.authorize(
            command(generation: 32),
            currentVersion: "1.0.0",
            warmIntents: [])
        try zeroWarm.transition(to: .drainingForUpdate)
        #expect(zeroWarm.record.reportedWarmIntent?.desiredGeneration == 32)
        #expect(zeroWarm.record.reportedWarmIntent?.modelId == nil)
    }

    @Test("manual live update refuses and blocked cannot be bypassed")
    func unsafeManualInvocation() {
        let update = command(generation: 42)
        let installing = UpdateLifecycleRecord(state: .installing, command: update)
        #expect(ManualUpdatePolicy.decide(
            providerRunning: true, record: installing) == .refuseLiveProvider)
        #expect(ManualUpdatePolicy.decide(
            providerRunning: true, record: UpdateLifecycleRecord()) ==
                .refuseLiveProvider)
        #expect(ManualUpdatePolicy.decide(
            providerRunning: false, record: installing) ==
                .resumeCoordinatorAuthorization(update))
        #expect(ManualUpdatePolicy.decide(
            providerRunning: false,
            record: UpdateLifecycleRecord(state: .blocked, command: update)) ==
                .noCoordinatorAuthorization)
    }

    @Test("release_update and additive heartbeat mirror frozen wire fields")
    func protocolMirror() throws {
        let incoming = #"{"type":"release_update","version":"2.0.0","platform":"macos-arm64","backend":"mlx-swift","binary_hash":"binary","bundle_hash":"bundle","metallib_hash":"metal","url":"https://cdn.example/release.tar.gz","desired_generation":7}"#
        guard case .releaseUpdate(let update) =
                try ProviderProtocolCodec.decodeCoordinatorMessage(from: incoming)
        else {
            Issue.record("release_update did not decode")
            return
        }
        #expect(update.desiredGeneration == 7)
        #expect(update.authorizedRelease.bundleHash == "bundle")

        let heartbeat = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
            status: .idle,
            stats: ProviderStats(),
            systemMetrics: SystemMetrics(
                memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
            updateLifecycleState: .modelReloading,
            warmIntent: WarmIntent(modelId: "model-a", desiredGeneration: 7)))
        let object = try #require(JSONSerialization.jsonObject(
            with: ProviderProtocolCodec.encodeProviderMessage(heartbeat)) as? [String: Any])
        #expect(object["update_lifecycle_state"] as? String == "model_reloading")
        let warm = try #require(object["warm_intent"] as? [String: Any])
        #expect(warm["model_id"] as? String == "model-a")
        #expect(warm["desired_generation"] as? Int == 7)
        #expect(warm["model_hash"] == nil)

        let readyHeartbeat = ProviderMessage.heartbeat(ProviderMessage.Heartbeat(
            status: .idle,
            stats: ProviderStats(),
            systemMetrics: SystemMetrics(
                memoryPressure: 0, cpuUsage: 0, thermalState: .nominal),
            updateLifecycleState: .ready,
            warmIntent: WarmIntent(desiredGeneration: 7)))
        let readyObject = try #require(JSONSerialization.jsonObject(
            with: ProviderProtocolCodec.encodeProviderMessage(readyHeartbeat))
            as? [String: Any])
        let readyWarm = try #require(readyObject["warm_intent"] as? [String: Any])
        #expect(readyWarm["desired_generation"] as? Int == 7)
        #expect(readyWarm["model_id"] == nil)

        let registration = ProviderMessage.register(ProviderMessage.Register(
            hardware: HardwareInfo(
                machineModel: "Mac16,5",
                chipName: "Apple M4 Max",
                chipFamily: .m4,
                chipTier: .max,
                memoryGb: 128,
                memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40,
                memoryBandwidthGbs: 546),
            models: [],
            backend: "mlx-swift",
            updateLifecycleState: .applicationVerifying,
            warmIntent: WarmIntent(modelId: "model-a", desiredGeneration: 7)))
        let registrationObject = try #require(JSONSerialization.jsonObject(
            with: ProviderProtocolCodec.encodeProviderMessage(registration))
            as? [String: Any])
        #expect(registrationObject["update_lifecycle_state"] as? String ==
            "application_verifying")
        #expect(registrationObject["warm_intent"] != nil)
    }

    @Test("lifecycle state and warm intent are read as one locked snapshot")
    func lockedLifecycleSnapshot() {
        let state = ProviderState()
        let warm = WarmIntent(modelId: "model-a", desiredGeneration: 7)
        state.setUpdateLifecycle(state: .modelReloading, warmIntent: warm)
        let snapshot = state.updateLifecycleSnapshot()
        #expect(snapshot.state == .modelReloading)
        #expect(snapshot.warmIntent == warm)
    }

    @Test("readiness is bound to the exact certified connection generation")
    func exactConnectionCertification() {
        #expect(UpdateConnectionCertificationPolicy.acceptsEvidence(
            evidenceGeneration: 4,
            currentGeneration: 4))
        #expect(!UpdateConnectionCertificationPolicy.acceptsEvidence(
            evidenceGeneration: 3,
            currentGeneration: 4))
        #expect(UpdateConnectionCertificationPolicy.canReportReady(
            restorationGeneration: 4,
            certifiedGeneration: 4,
            currentGeneration: 4))
        #expect(!UpdateConnectionCertificationPolicy.canReportReady(
            restorationGeneration: 3,
            certifiedGeneration: 4,
            currentGeneration: 4))
        #expect(!UpdateConnectionCertificationPolicy.canReportReady(
            restorationGeneration: 4,
            certifiedGeneration: 5,
            currentGeneration: 5))
    }

    @Test("latest desired-model frame is retained and replayed once")
    func deferredDesiredModelsReplay() {
        var buffer = DeferredDesiredModelsBuffer()
        let first = CoordinatorMessage.DesiredModelEntry(
            modelName: "m", desiredBuild: "build-1")
        let latest = CoordinatorMessage.DesiredModelEntry(
            modelName: "m", desiredBuild: "build-2", previousBuild: "build-1")
        buffer.record([first])
        buffer.record([latest])
        #expect(buffer.take() == [latest])
        #expect(buffer.take() == nil)
    }

    @Test("production staging requires app layout and signed plist version binding")
    func signedAppVersionBinding() throws {
        #expect(throws: UpdateError.self) {
            try SelfUpdater.verifyAppBundleRequirement(
                hasAppBundle: false,
                required: true)
        }
        try SelfUpdater.verifyAppBundleRequirement(
            hasAppBundle: false,
            required: false)
        try SelfUpdater.verifyAppBundleRequirement(
            hasAppBundle: true,
            required: true)

        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("Darkbloom-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents,
            withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleVersion": "2.0.0",
            "CFBundleShortVersionString": "2.0.0",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try SelfUpdater.verifySignedAppVersion(
            app: app,
            claimedVersion: "2.0.0")
        #expect(throws: UpdateError.self) {
            try SelfUpdater.verifySignedAppVersion(
                app: app,
                claimedVersion: "3.0.0")
        }
    }


    @Test("update exec environment clears secrets and process certificates")
    func execEnvironmentScrub() {
        let clean = ProcessLifecycle.sanitizedEnvironmentForExec([
            "PATH": "/usr/bin",
            "DARKBLOOM_AUTH_TOKEN": "secret",
            "API_KEY": "secret",
            "PROCESS_EVIDENCE_CERT": "stale",
            "COORDINATOR_SESSION_ID": "stale",
            "DARKBLOOM_AUTH_TOKEN_PATH": "/tmp/auth-token",
            "DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "8",
        ])
        #expect(clean == [
            "PATH": "/usr/bin",
            "DARKBLOOM_AUTH_TOKEN_PATH": "/tmp/auth-token",
            "DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "8",
        ])
    }

    private func command(
        version: String = "2.0.0",
        generation: UInt64
    ) -> AuthorizedReleaseUpdate {
        AuthorizedReleaseUpdate(
            version: version,
            platform: "macos-arm64",
            backend: "mlx-swift",
            binaryHash: String(repeating: "a", count: 64),
            bundleHash: String(repeating: "b", count: 64),
            metallibHash: String(repeating: "c", count: 64),
            url: "https://cdn.example/release.tar.gz",
            desiredGeneration: generation)
    }

    private func intent(
        model: String,
        slot: String,
        generation: UInt64
    ) -> WarmIntent {
        WarmIntent(
            modelId: model,
            modelHash: "hash-\(model)",
            slotId: slot,
            kvBackend: "paged",
            kvQuantization: "fp16",
            mtpModelId: "mtp-\(model)",
            desiredGeneration: generation)
    }
}
