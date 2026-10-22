import Foundation
import MLX
import MLXLLM
import MLXVLM
import ProviderCoreFoundation
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

#if DEBUG
/// Each scenario needs its own filtered process: injected faults deliberately
/// retain real model roots and poison GLM admission until process exit.
@Suite(.serialized, .enabled(if:
    ProcessInfo.processInfo.environment["DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST"] == "1"
        && ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM_RESIDENCY_INTEGRATION"] != nil))
struct GLM5NextResidencyIntegrationTests {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private weak var storedOwner: GLM5NextNativeOperationOwner?
        private weak var storedModel: AnyObject?
        func observe(_ owner: GLM5NextNativeOperationOwner) {
            lock.withLock { storedOwner = owner; storedModel = owner.modelForTesting }
        }
        var owner: GLM5NextNativeOperationOwner? { lock.withLock { storedOwner } }
        var model: AnyObject? { lock.withLock { storedModel } }
    }
    private actor EndGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Bool, Never>?
        private(set) var calls = 0
        func end() async -> Bool {
            calls += 1
            return await withCheckedContinuation { continuation in
                release = continuation; entered = true
                let waiters = entryWaiters; entryWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }
        func finish(_ success: Bool) { release?.resume(returning: success); release = nil }
    }
    private actor CompletionCount {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test func actualFactoryAndOwnerResidencyContract() async throws {
        try #require(!GLM5NextLoadFaultState.isRetained, "Use a fresh isolated process")
        let scenario = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM_RESIDENCY_INTEGRATION"])
        switch scenario {
        case "start-fault": try await failedStartPreservesOuterLoadAccounting()
        case "complete-success": try await concurrentCompletion(endSucceeds: true)
        case "end-fault": try await concurrentCompletion(endSucceeds: false)
        default: Issue.record("Unknown residency scenario: \(scenario)")
        }
    }

    private func failedStartPreservesOuterLoadAccounting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glm-residency-host-\(UUID())")
        let snapshot = root.appendingPathComponent(ModelScanner.cacheDirectoryName(for: GLM5NextLocalQualification.modelID))
            .appendingPathComponent("snapshots/\(String(repeating: "a", count: 40))")
        let fixture = try GLM5NextManagedFixture(modelID: GLM5NextLocalQualification.modelID,
            directory: snapshot, chatTemplate: GLM5NextManagedFixture.shippedTemplate())
        let selection = root.appendingPathComponent("selection.json")
        try GLM5NextLocalSelectionFile.write(catalog: fixture.catalog, manifest: fixture.manifest,
            maximumContextLength: 32, to: selection)
        let oldCache = ModelScanner.configuredCacheDirectory
        let keys = [GLM5NextLocalQualification.environmentKey, PrefixCachePolicy.environmentFlag]
        let oldEnvironment = ProcessInfo.processInfo.environment
        defer {
            ModelScanner.configureCacheDirectory(oldCache)
            for key in keys {
                if let value = oldEnvironment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setenv(GLM5NextLocalQualification.environmentKey, selection.path, 1)
        setenv(PrefixCachePolicy.environmentFlag, "0", 1)
        ModelScanner.configureCacheDirectory(root.path)
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: snapshot,
            modelName: GLM5NextLocalQualification.modelID))
        let server = StandaloneServer(config: .init(
            runtimeCapabilities: ModelRuntimeRequirements.glm5NextRequiredCapabilities,
            engineV2KVBackend: "paged", mtpMode: .on), models: [model], kvBudgetForTesting: nil)
        let policy = MiMoV26WiredResidency.Policy(), captured = Capture()
        let residency = GLM5NextWiredResidency(policy: policy, policyEntry: UUID(), ceiling: { 1 },
            startTicket: { false }, endTicket: { Issue.record("Failed start was incorrectly ended"); return true })
        let before = await server.fleetKVBudgetBytes(extraWeightBytes: 0)
        await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
            try await GLM5NextNativeOperationOwner.$residencyForTesting.withValue(residency) {
                try await GLM5NextNativeOperationOwner.$observeConstructionForTesting.withValue({ captured.observe($0) }) {
                    try await server.ensureModelLoaded(model.id)
                }
            }
        }
        // Weak references prove that neither the test observer nor a returned
        // bundle is what keeps the actual model and owner alive.
        let owner = try #require(captured.owner)
        let bridge = try #require(owner.bridgeForTesting)
        #expect(captured.model != nil && owner.hasBindingForTesting)
        #expect(residency.currentPhase == .retainedFault && policy.registeredCount == 1)
        #expect(await server.slots[model.id] == nil)
        let state = await server.glm5NextLoadRetentionForTesting(model.id)
        #expect(state.pendingLease && state.loading)
        #expect(await server.debugOutstandingKVReservationBytes() > 0)
        #expect(!(await server.serviceBudgetIsIdleForTesting()))
        #expect(GLM5NextLoadFaultState.retainedResidentBytes >= UInt64(fixture.manifest.totalSizeBytes))
        #expect(await server.fleetKVBudgetBytes(extraWeightBytes: 0) < before)
        let claim = await bridge.slotKVBytesClaim()
        #expect(claim > 0)
        await bridge.updateKVBytesCapacity(claim + (1 << 20))
        #expect(await bridge.slotKVBytesClaim() == claim)
        await bridge.updateKVBytesCapacity(max(0, claim - 1))
        #expect(await bridge.slotKVBytesClaim() == claim)
        #expect(!(await bridge.canSubmitWithNativeOwner()))
        #expect(throws: (any Error).self) { try GLM5NextArtifactOwnership.acquire(plan: fixture.plan()) }
        // No cleanup/refund: this process intentionally retains the fixture files.
        GLM5NextLoadFaultState.retain([server, fixture])
    }

    private func concurrentCompletion(endSucceeds: Bool) async throws {
        let fixture = try GLM5NextProtectedFactoryFixture()
        let oldCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(fixture.root.appendingPathComponent("scanner").path)
        defer { ModelScanner.configureCacheDirectory(oldCache) }
        let container = try await fixture.load(), tokenizer = await container.tokenizer
        let gate = EndGate(), completions = CompletionCount(), policy = MiMoV26WiredResidency.Policy()
        let residency = GLM5NextWiredResidency(policy: policy, policyEntry: UUID(), ceiling: { 1 },
            startTicket: { true }, endTicket: { await gate.end() })
        let bundle = try await GLM5NextNativeOperationOwner.$residencyForTesting.withValue(residency) {
            try await EngineV2SlotFactory.makeProductionBundle(
                modelId: fixture.plan.weights.catalog.id, modelType: "glm5_next", isVLM: false,
                modelDirectory: fixture.directory, container: container, tokenizer: TokenizerHandle(tokenizer),
                sizing: fixture.sizing, kvBytesCapacity: fixture.kvBytesCapacity,
                maxConcurrentRequests: 1, kvBudget: fixture.budget, kvBackendConfig: "paged",
                weightHash: fixture.plan.weights.manifest.aggregateSHA256,
                specDecPreparation: fixture.mtpPreparation,
                assemblyOverrides: .init(completeCheckpointIdentity: fixture.identity),
                environment: fixture.environment, startServingTelemetry: false)
        }
        fixture.bridges.append(bundle.bridge)
        let nativeOwner = await bundle.bridge.glm5NextNativeOwner
        let owner = try #require(nativeOwner)
        #expect(owner.hasBindingForTesting && residency.currentPhase == .held)
        let grant = await bundle.bridge.slotKVBytesClaim()
        let first = Task { () -> Bool in
            do { try await bundle.bridge.shutdownGLM5NextReportingCompletion(); await completions.increment(); return true }
            catch { return false }
        }
        await gate.waitUntilEntered()
        // The SDK receipt has arrived, but ticket completion has not. Exercise
        // a second actual bridge completion while the first end is suspended.
        let receipt = try #require(await bundle.bridge.nativeShutdownResult)
        guard case .quiescent(let nativeReceipt) = receipt else { Issue.record("Missing native quiescence"); await gate.finish(endSucceeds); _ = await first.value; return }
        let second = Task { () -> Bool in
            do { try await bundle.bridge.shutdownGLM5NextReportingCompletion(); await completions.increment(); return true }
            catch { return false }
        }
        for _ in 0..<5000 {
            if owner.completionsInFlightForTesting == 2 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.completionsInFlightForTesting == 2)
        #expect(owner.hasBindingForTesting && policy.registeredCount == 1)
        #expect(await completions.value == 0)
        #expect(await bundle.bridge.slotKVBytesClaim() == grant)
        await gate.finish(endSucceeds)
        let outcomes = await (first.value, second.value)
        #expect(outcomes.0 == endSucceeds && outcomes.1 == endSucceeds)
        #expect(await gate.calls == 1)
        if endSucceeds {
            #expect(!owner.hasBindingForTesting && policy.registeredCount == 0)
            #expect(await completions.value == 2)
            try await fixture.close()
        } else {
            #expect(owner.hasBindingForTesting && policy.registeredCount == 1)
            #expect(await completions.value == 0)
            #expect(GLM5NextLoadFaultState.isRetained)
            #expect(await bundle.bridge.slotKVBytesClaim() == grant)
            // This is the actual eviction/unload failure accounting helper.
            await GLM5NextRetirement.retainUnpublished(bundle, with: [fixture])
            #expect(GLM5NextLoadFaultState.retainedResidentBytes >= UInt64(grant))
            await #expect(throws: GLM5NextManagedLoadError.retirementUnproven) {
                try await owner.complete(nativeReceipt)
            }
            #expect(await gate.calls == 1)
            fixture.recordUnprovenRetirement()
        }
    }
}
#endif
