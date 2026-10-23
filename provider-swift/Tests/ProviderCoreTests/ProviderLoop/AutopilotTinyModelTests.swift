import Foundation
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

// Autopilot operations through the real loader: a tiny synthetic checkpoint
// in a temporary model cache, scripted load-admission memory, and a live
// operation-scoped lease granted for each operation and ended after it.

extension TinyModelLoadTests {
    @Suite("Autopilot placements")
    struct AutopilotPlacementCases {
        private static let session = "tiny-session"
        private static let revision = "tiny"

        @Test("An operation's inventory target keeps serving after the lease until an admin unload")
        func adoptedInventoryServesAfterTheLease() async throws {
            _ = LiveInferenceFixtures.ensureMetallibColocated()
            let checkpoint = try TinyModelCheckpoint(seed: 21)
            defer { checkpoint.remove() }
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }
            try await checkpoint.withModelCache {
                let model = checkpoint.modelID
                let loop = try await makeLoop(checkpoint, sandbox: sandbox, asInventory: true)
                #expect(await loop.autopilotServesModel(model) == false)

                await lease(loop, enabled: true)
                let loaded = try #require(
                    await loop.runAutopilotCommandForTesting(command("adopt", load: model, hold: 600)))
                #expect(loaded.status == .succeeded)
                #expect(loaded.modelAutopilot.adoptedModels == [model])
                await lease(loop, enabled: false)

                // The lease ended. The model stays advertised, adopted and held,
                // and every serving entry point admits it.
                #expect(await loop.modelAutopilotEnabled == false)
                #expect(await loop.isModelAdvertised(model))
                #expect(await loop.autopilotServesModel(model))
                let snapshot = try #require(await loop.state.modelAutopilot)
                #expect(snapshot.adoptedModels == [model])
                #expect(snapshot.heldModels?.map(\.modelId) == [model])
                #expect(snapshot.capabilities?.contains("inventory_adoption") == true)
                try await loop.throwIfRefusingNewLocalWork(modelId: model)
                try await loop.ensureModelLoaded(modelId: model)
                #expect(await loop.fastAdmissionReject(modelId: model) == false)
                let bridge = try #require(await loop.slotBridgeForTesting(modelId: model))
                let generation = await TinyGeneration.run(bridge: bridge, modelID: model)
                generation.check()

                // An admin unload under the next operation's lease withdraws it.
                await loop.setIdleForTesting(model, since: .now.advanced(by: .seconds(-60)))
                await loop.ageAutopilotResidentsForTesting()
                await lease(loop, enabled: true)
                let released = try #require(await loop.runAutopilotCommandForTesting(
                    command("release", unload: [model], residents: [model])))
                #expect(released.status == .succeeded)
                await lease(loop, enabled: false)
                #expect(await loop.modelLoadingResidentIDs().isEmpty)
                #expect(await loop.isModelAdvertised(model) == false)
                #expect(await loop.autopilotServesModel(model) == false)
                #expect(await loop.state.modelAutopilot?.adoptedModels == nil)
                #expect(await loop.state.modelAutopilot?.heldModels == nil)
            }
        }

        @Test("A held inventory model idles out only after its hold expires, then is withdrawn")
        func heldInventoryIdlesOutAfterItsHold() async throws {
            _ = LiveInferenceFixtures.ensureMetallibColocated()
            let checkpoint = try TinyModelCheckpoint(seed: 23)
            defer { checkpoint.remove() }
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }
            try await checkpoint.withModelCache {
                let model = checkpoint.modelID
                let loop = try await makeLoop(checkpoint, sandbox: sandbox, asInventory: true)
                await lease(loop, enabled: true)
                let held = await loop.runAutopilotCommandForTesting(command("held", load: model, hold: 600))
                #expect(held?.status == .succeeded)
                await lease(loop, enabled: false)

                let timeout = Duration.seconds(60)
                await loop.setIdleForTesting(model, since: .now.advanced(by: .seconds(-7_200)))
                await loop.tickIdleMonitor(timeout: timeout)
                #expect(await loop.modelLoadingResidentIDs() == [model])
                await loop.setAutopilotHoldForTesting(model, until: .now.advanced(by: .seconds(-30)))
                await loop.tickIdleMonitor(timeout: timeout)
                #expect(await loop.modelLoadingResidentIDs() == [model])
                await loop.setAutopilotHoldForTesting(model, until: .now.advanced(by: .seconds(-61)))
                await loop.tickIdleMonitor(timeout: timeout)
                #expect(await loop.modelLoadingResidentIDs().isEmpty)
                #expect(await loop.isModelAdvertised(model) == false)
                #expect(await loop.autopilotServesModel(model) == false)
            }
        }

        @Test("An ordinary target is held but not adopted, and a failed operation places nothing")
        func ordinaryTargetAndFailedOperation() async throws {
            _ = LiveInferenceFixtures.ensureMetallibColocated()
            let checkpoint = try TinyModelCheckpoint(seed: 25)
            defer { checkpoint.remove() }
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }
            try await checkpoint.withModelCache {
                let model = checkpoint.modelID
                let loop = try await makeLoop(checkpoint, sandbox: sandbox, asInventory: false)
                await lease(loop, enabled: true)
                await ModelLoadingFixtures.setAvailableMemory(loop, gb: 0)
                let failed = try #require(
                    await loop.runAutopilotCommandForTesting(command("no-room", load: model, hold: 600)))
                #expect(failed.status == .failed)
                #expect(failed.error == "insufficient_memory_without_other_victims")
                var placements = await loop.autopilotPlacementsForTesting
                #expect(placements.adopted.isEmpty && placements.held.isEmpty)

                await loop.setEngineV2SlotHooksForTesting(nil)
                let ordinary = await loop.runAutopilotCommandForTesting(command("ordinary", load: model, hold: 600))
                #expect(ordinary?.status == .succeeded)
                await lease(loop, enabled: false)
                placements = await loop.autopilotPlacementsForTesting
                #expect(placements.adopted.isEmpty)
                #expect(placements.held == [model])
                #expect(await loop.autopilotHoldsModel(model))
                #expect(await loop.evictableModelSlots().isEmpty)
                #expect(await loop.unloadModel(model))
            }
        }

        @Test("A stalled operation fails as transition_stalled and releases its load")
        func stalledOperationIsCancelled() async throws {
            _ = LiveInferenceFixtures.ensureMetallibColocated()
            let checkpoint = try TinyModelCheckpoint(seed: 27)
            defer { checkpoint.remove() }
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }
            try await checkpoint.withModelCache {
                let model = checkpoint.modelID
                // The load parks inside its critical section until its owner is cancelled.
                let loop = try await makeLoop(checkpoint, sandbox: sandbox, asInventory: true) { _ in
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                }
                await lease(loop, enabled: true)
                let recorder = AutopilotRecorder()
                await loop.handleModelAutopilot(command("stalls", load: model, hold: 600), send: SendHandle(recorder.append))
                #expect(await modelLoadingWaitUntil { await loop.modelLoadingInFlightIDs() == [model] })

                let start = ContinuousClock.now
                await loop.superviseTransitions(now: start)
                await loop.superviseTransitions(now: start + .seconds(600))
                let task = await loop.autopilotTask
                await task?.value
                #expect(recorder.statuses.last?.status == .failed)
                #expect(recorder.statuses.last?.error == "transition_stalled")
                await lease(loop, enabled: false)
                #expect(await loop.autopilotBusyReasons().isEmpty)
                #expect(await loop.modelLoadingResidentIDs().isEmpty)
                #expect(await loop.outstandingKVReservationBytesForTesting() == 0)
                let placements = await loop.autopilotPlacementsForTesting
                #expect(placements.adopted.isEmpty && placements.held.isEmpty)
                #expect(await loop.state.modelAutopilot?.transitionStalls?.map(\.transition)
                    == ["autopilot_operation", "model_loading"])
            }
        }

        @Test("A stalled preload is answered, never interrupted, and still warms its model")
        func stalledPreloadIsAnsweredAndStillCompletes() async throws {
            _ = LiveInferenceFixtures.ensureMetallibColocated()
            let checkpoint = try TinyModelCheckpoint(seed: 29)
            defer { checkpoint.remove() }
            let sandbox = try ModelLoadingSandbox()
            defer { sandbox.remove() }
            try await checkpoint.withModelCache {
                let model = checkpoint.modelID
                let loop = try await makeLoop(checkpoint, sandbox: sandbox, asInventory: false)
                // Another load holds the gate past the bound.
                await loop.modelLoadingSetLoadingAny(true)
                let replies = AutopilotRecorder()
                await loop.handleLoadModelRequest(modelId: model, send: SendHandle(replies.append))
                #expect(await modelLoadingWaitUntil { await loop.modelLoadingLoadGateWaiterCount() == 1 })

                let start = ContinuousClock.now
                await loop.superviseTransitions(now: start)
                await loop.superviseTransitions(now: start + .seconds(600))
                #expect(replies.legacyStatuses == [.started, .failed])
                #expect(replies.legacyErrors.last == "transition_stalled")
                // The preload stays parked; the gate belongs to another owner
                // and is never force-released.
                #expect(await loop.modelLoadingLoadGateWaiterCount() == 1)
                #expect(await loop.autopilotBusyReasons() == [.loadGate])

                // Once the gate opens, the untracked preload loads the model
                // as usual and does not report a second outcome.
                await loop.modelLoadingSetLoadingAny(false)
                await loop.releaseLoadGateWaiters()
                #expect(await modelLoadingWaitUntil { await loop.modelLoadingResidentIDs() == [model] })
                #expect(await modelLoadingWaitUntil { await loop.autopilotBusyReasons().isEmpty })
                #expect(replies.legacyStatuses == [.started, .failed])
                #expect(await loop.unloadModel(model))
            }
        }

        // MARK: - Fixture

        private func makeLoop(_ checkpoint: TinyModelCheckpoint, sandbox: ModelLoadingSandbox, asInventory: Bool,
                              beforeModelLoad: (@Sendable (String) async -> Void)? = nil) async throws -> ProviderLoop {
            var info = try checkpoint.scannedModelInfo()
            // Adoption requires a verified weight hash.
            let weightHash = try #require(
                WeightHasher.computeHash(snapshotDir: try checkpoint.resolvedSnapshot(), modelID: checkpoint.modelID))
            info.weightHash = weightHash
            let settings = ModelAutopilotSettings(enabled: true, consentRecorded: true,
                selectedModels: [checkpoint.modelID], revision: Self.revision, minIdleSeconds: 1)
            let loop = try ProviderLoop(
                config: ProviderLoopConfig(
                    coordinatorURL: "ws://127.0.0.1:0/ignored", hardware: ModelLoadingFixtures.defaultHardware,
                    models: asInventory ? [] : [info],
                    config: ProviderConfig(
                        provider: ProviderSettings(name: "autopilot-tiny-test", memoryReserveGB: 0),
                        backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3, mtpMode: .off,
                            modelAutopilot: settings),
                        coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)),
                    autopilotInventory: asInventory ? [info] : []),
                attestationSigner: nil, beforeModelLoad: beforeModelLoad,
                kvBudgetForTesting: ScriptedProviderMemory.budget(modelIDs: [checkpoint.modelID]))
            await loop.setDaemonStateFileForTesting(sandbox.daemonStateFile)
            await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
            return loop
        }

        private func lease(_ loop: ProviderLoop, enabled: Bool) async {
            await loop.handleAutopilotControl(.init(sessionId: Self.session, revision: Self.revision, enabled: enabled,
                expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 120_000))
        }

        private func command(_ id: String, load: String? = nil, unload: [String] = [], residents: [String] = [],
                             hold: Int? = nil) -> ModelAutopilotCommand {
            ModelAutopilotCommand(commandId: id, loadModelId: load, unloadModelIds: unload,
                expectedResidentModels: residents, expiresAtMs: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000,
                leaseSeconds: 0, sessionId: Self.session, revision: Self.revision, holdSeconds: hold)
        }
    }
}
