import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

@Suite("Onboarding live model preparation")
@MainActor
struct OnboardingPreparationLiveTests {
    @Test("Recommendation prefers a compatible installed model without hardcoded ids")
    func recommendationPrefersInstalled() async throws {
        let installed = catalogModel(id: "catalog/already-here", minRAM: 8, size: 2_000_000_000)
        let larger = catalogModel(id: "catalog/larger", minRAM: 24, size: 4_000_000_000)
        let service = service(snapshot: snapshot(
            catalog: [larger, installed],
            local: [localModel(id: installed.id)],
            memoryGB: 32
        ))

        let plan = try await service.fetchPlan()

        #expect(plan.recommendedModelID == installed.id)
        #expect(plan.choices.map(\.id).sorted() == [installed.id, larger.id].sorted())
        #expect(plan.choices.first { $0.id == installed.id }?.isInstalled == true)
    }

    @Test("Without a local model the strongest minimum-RAM fit is recommended")
    func recommendationUsesCatalogFit() async throws {
        let small = catalogModel(id: "catalog/small", minRAM: 8, size: 1_000_000_000)
        let large = catalogModel(id: "catalog/large", minRAM: 24, size: 4_000_000_000)
        let service = service(snapshot: snapshot(catalog: [small, large], memoryGB: 32))

        let plan = try await service.fetchPlan()

        #expect(plan.recommendedModelID == large.id)
    }

    @Test("A resumed model is admitted when remaining bytes and the 2 GiB reserve fit")
    func resumedDownloadUsesRemainingBytes() async throws {
        let model = catalogModel(
            id: "catalog/mostly-staged",
            minRAM: 16,
            size: 10_000_000_000
        )
        let available = Int64(4 * 1_073_741_824)
        let reserve = Int64(2 * 1_073_741_824)
        let remaining: Int64 = 1_000_000_000
        let service = service(
            snapshot: snapshot(
                catalog: [model],
                memoryGB: 32,
                downloadPlans: [
                    model.id: CLIModelDownloadStoragePlan(
                        remainingBytes: remaining,
                        reserveBytes: reserve,
                        requiredAvailableBytes: remaining + reserve,
                        availableBytes: available,
                        hasSufficientCapacity: true
                    ),
                ]
            ),
            availableStorageBytes: UInt64(available)
        )

        // The 10 GB full model plus reserve does not fit in ~4.3 GB, while
        // the authoritative 1 GB remainder plus the 2 GiB reserve does.
        let plan = try await service.fetchPlan()
        #expect(plan.recommendedModelID == model.id)
        #expect(plan.choices.first?.sizeBytes == 10_000_000_000)
    }

    @Test("Resume planning still holds back the full 2 GiB reserve")
    func resumedDownloadPreservesReserve() async {
        let model = catalogModel(
            id: "catalog/reserve-boundary",
            minRAM: 16,
            size: 10_000_000_000
        )
        let available: Int64 = 3_000_000_000
        let reserve = Int64(2 * 1_073_741_824)
        let remaining: Int64 = 1_000_000_000
        let service = service(snapshot: snapshot(
            catalog: [model],
            memoryGB: 32,
            downloadPlans: [
                model.id: CLIModelDownloadStoragePlan(
                    remainingBytes: remaining,
                    reserveBytes: reserve,
                    requiredAvailableBytes: remaining + reserve,
                    availableBytes: available,
                    hasSufficientCapacity: false
                ),
            ]
        ))

        await #expect(throws: OnboardingPreparationServiceError.noCompatibleModel) {
            try await service.fetchPlan()
        }
    }

    @Test("Unknown fit, excessive RAM, excessive disk, and embedding-only rows yield no compatible model")
    func noCompatibleModel() async {
        let entries = [
            catalogModel(id: "catalog/no-fit", minRAM: nil, size: 1_000_000),
            catalogModel(id: "catalog/too-much-ram", minRAM: 64, size: 1_000_000),
            catalogModel(id: "catalog/too-much-disk", minRAM: 8, size: 50_000_000_000),
            catalogModel(id: "catalog/embedding", minRAM: 8, size: 1_000_000, type: "embeddings"),
        ]
        let service = service(
            snapshot: snapshot(catalog: entries, memoryGB: 16),
            availableStorageBytes: 12 * 1_073_741_824
        )

        await #expect(throws: OnboardingPreparationServiceError.noCompatibleModel) {
            try await service.fetchPlan()
        }
    }

    @Test("No-compatible and catalog failures surface in flow and catalog retry recovers")
    func flowCatalogRecovery() async {
        let model = OnboardingModelChoice(
            id: "dynamic/recovered",
            displayName: "Recovered",
            summary: "Recovered from retry",
            sizeBytes: 1_000,
            minimumMemoryGB: 8,
            isInstalled: false
        )
        let preparation = ScriptedPreparationService(plans: [
            .failure(ModelCatalogCLIError.exited(1, message: "catalog offline")),
            .success(.init(choices: [model], recommendedModelID: model.id, fetchedAt: .now)),
        ])
        let flow = OnboardingFlowModel(
            startingAt: .preparation,
            diagnosticsRunner: nil,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: preparation
        )

        await flow.runAutomaticWorkForCurrentStep()
        #expect(flow.preparationPhase == .catalogFailed)
        #expect(flow.preparationFailureDetail == "catalog offline")

        flow.retryPreparation()
        #expect(await eventually { flow.preparationPhase == .choosingModel })
        #expect(flow.selectedModelID == model.id)

        let noCompatible = OnboardingFlowModel(
            startingAt: .preparation,
            diagnosticsRunner: nil,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: ScriptedPreparationService(plans: [
                .failure(OnboardingPreparationServiceError.noCompatibleModel),
            ])
        )
        await noCompatible.runAutomaticWorkForCurrentStep()
        #expect(noCompatible.preparationPhase == .noCompatibleModel)
        #expect(!noCompatible.canContinue)
    }

    @Test("Setup start adapter emits the exact noninteractive model and local-endpoint argv")
    func exactStartArguments() async throws {
        let runner = RecordingProviderCLI()
        let adapter = ProcessSetupStartCLI(runner: runner, timeout: .seconds(37))

        try await adapter.start(modelID: "catalog/runtime-choice")

        #expect(runner.calls == [
            .init(
                arguments: ["start", "--model", "catalog/runtime-choice", "--local-endpoint"],
                timeout: .seconds(37)
            ),
        ])
    }

    @Test("A stale ready phase cannot advance without a completed provider start")
    func providerStartGatesVerification() {
        let flow = OnboardingFlowModel(
            startingAt: .preparation,
            diagnosticsRunner: nil,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: nil
        )
        flow.preparationPhase = .ready
        flow.providerStartCompleted = false

        #expect(!flow.canContinue)
        flow.continueToNextStep()
        #expect(flow.step == .preparation)
    }

    @Test("Start waits for current live selected-model and endpoint evidence")
    func startPollsMachineEvidence() async {
        let model = modelChoice(installed: true)
        let service = PreparationAttemptService(model: model)
        let evidence = ProviderEvidenceBox(ProviderEvidenceBox.missing)
        let flow = OnboardingFlowModel(
            startingAt: .preparation,
            diagnosticsRunner: nil,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: service,
            providerEvidenceProvider: evidence.read,
            preparationEvidencePollInterval: .milliseconds(5),
            preparationEvidenceTimeout: .seconds(10)
        )

        await flow.runAutomaticWorkForCurrentStep()
        flow.startPreparation()
        #expect(await eventually { flow.preparationPhase == .startingProvider })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(flow.preparationPhase == .startingProvider)
        #expect(!flow.providerStartCompleted)

        evidence.set(providerEvidence(modelID: model.id))
        #expect(await eventually { flow.preparationPhase == .ready })
        #expect(flow.providerStartCompleted)
    }

    @Test("Live-evidence timeout is a retryable start failure")
    func startEvidenceTimeoutCanRetry() async {
        let model = modelChoice(installed: true)
        let service = PreparationAttemptService(model: model)
        let evidence = ProviderEvidenceBox(ProviderEvidenceBox.missing)
        let flow = OnboardingFlowModel(
            startingAt: .preparation,
            diagnosticsRunner: nil,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: service,
            providerEvidenceProvider: evidence.read,
            preparationEvidencePollInterval: .milliseconds(5),
            preparationEvidenceTimeout: .milliseconds(500)
        )

        await flow.runAutomaticWorkForCurrentStep()
        flow.startPreparation()
        #expect(await eventually { flow.preparationPhase == .startFailed })
        #expect(flow.preparationFailureDetail?.contains("did not confirm") == true)

        evidence.set(providerEvidence(modelID: model.id))
        flow.retryPreparation()
        #expect(await eventually { flow.preparationPhase == .ready })
        #expect(service.startCalls == 2)
    }

    @Test("A completed initial download retries start without redownloading")
    func newlyDownloadedModelRetriesOnlyStart() async {
        let model = modelChoice(installed: false)
        let service = PreparationAttemptService(
            model: model,
            startResults: [.failure(PreparationAttemptError.startFailed), .success(())]
        )
        let evidence = ProviderEvidenceBox(providerEvidence(modelID: model.id))
        let flow = OnboardingFlowModel(
            startingAt: .preparation,
            diagnosticsRunner: nil,
            accountLinkRunner: nil,
            enrollmentRunner: nil,
            preparationService: service,
            providerEvidenceProvider: evidence.read,
            preparationEvidencePollInterval: .milliseconds(5),
            preparationEvidenceTimeout: .seconds(10)
        )

        await flow.runAutomaticWorkForCurrentStep()
        #expect(flow.selectedPreparationChoice?.isInstalled == false)
        flow.startPreparation()
        #expect(await eventually { flow.preparationPhase == .startFailed })
        #expect(flow.downloadCompletedModelID == model.id)
        #expect(service.downloadCalls == 1)

        flow.retryPreparation()
        #expect(await eventually { flow.preparationPhase == .ready })
        #expect(service.downloadCalls == 1)
        #expect(service.startCalls == 2)
    }

    @Test("Resume evidence rejects stale files and dead daemon processes")
    func providerEvidenceRequiresFreshLiveProcess() {
        let now = Date(timeIntervalSince1970: 2_000)
        let identity = ProcessIdentity(pid: 42, startTimeMicros: 100)
        let fresh = DaemonState(
            pid: 42,
            processIdentity: identity,
            version: "test",
            writtenAt: 1_990,
            startedAt: 1_900,
            currentModel: "catalog/model",
            warmModels: ["catalog/model"]
        )
        let endpoint = LocalEndpointInfo(
            host: "127.0.0.1",
            port: 8080,
            apiKey: "test",
            version: "test",
            pid: 42,
            processIdentity: identity,
            updatedAt: "1970-01-01T00:33:20Z"
        )

        #expect(OnboardingProviderEvidence(
            daemonState: fresh,
            localEndpoint: endpoint,
            processIsAlive: true,
            localEndpointProcessIsAlive: true,
            sampledAt: now
        ).reportsStarted(modelID: "catalog/model"))
        #expect(!OnboardingProviderEvidence(
            daemonState: fresh,
            localEndpoint: endpoint,
            processIsAlive: false,
            localEndpointProcessIsAlive: true,
            sampledAt: now
        ).reportsStarted(modelID: "catalog/model"))

        #expect(!OnboardingProviderEvidence(
            daemonState: fresh,
            localEndpoint: endpoint,
            processIsAlive: true,
            localEndpointProcessIsAlive: false,
            sampledAt: now
        ).reportsStarted(modelID: "catalog/model"))

        var mismatchedEndpoint = endpoint
        mismatchedEndpoint.pid = 43
        #expect(!OnboardingProviderEvidence(
            daemonState: fresh,
            localEndpoint: mismatchedEndpoint,
            processIsAlive: true,
            localEndpointProcessIsAlive: true,
            sampledAt: now
        ).reportsStarted(modelID: "catalog/model"))

        var stale = fresh
        stale.writtenAt = 1_800
        #expect(!OnboardingProviderEvidence(
            daemonState: stale,
            localEndpoint: endpoint,
            processIsAlive: true,
            localEndpointProcessIsAlive: true,
            sampledAt: now
        ).reportsStarted(modelID: "catalog/model"))
    }

    private func modelChoice(installed: Bool) -> OnboardingModelChoice {
        OnboardingModelChoice(
            id: "catalog/model",
            displayName: "Model",
            summary: "Test model",
            sizeBytes: 1_000,
            minimumMemoryGB: 8,
            isInstalled: installed
        )
    }

    private func providerEvidence(modelID: String) -> OnboardingProviderEvidence {
        let now = Date().timeIntervalSince1970
        let processIdentity = ProcessIdentity.current()!
        let pid = processIdentity.pid
        return OnboardingProviderEvidence(
            daemonState: DaemonState(
                pid: pid,
                processIdentity: processIdentity,
                version: "test",
                writtenAt: now,
                startedAt: now - 1,
                currentModel: modelID,
                warmModels: [modelID]
            ),
            localEndpoint: LocalEndpointInfo(
                host: "127.0.0.1",
                port: 18080,
                apiKey: "test",
                version: "test",
                pid: pid,
                processIdentity: processIdentity,
                updatedAt: "2026-01-01T00:00:00Z"
            ),
            processIsAlive: true,
            localEndpointProcessIsAlive: true
        )
    }

    private func service(
        snapshot: ModelLibrarySnapshot,
        availableStorageBytes: UInt64 = 100 * 1_073_741_824
    ) -> OnboardingPreparationService {
        OnboardingPreparationService(
            catalog: SnapshotCatalogCLI(snapshot: snapshot),
            startCLI: NoopSetupStartCLI(),
            availableStorageBytes: { availableStorageBytes }
        )
    }

    private func snapshot(
        catalog: [CLICatalogModel],
        local: [CLILocalModelEntry] = [],
        memoryGB: Int,
        downloadPlans: [String: CLIModelDownloadStoragePlan] = [:]
    ) -> ModelLibrarySnapshot {
        ModelLibrarySnapshot(
            catalog: catalog,
            local: local,
            downloadPlans: downloadPlans,
            warmModelIDs: [],
            servingModelID: nil,
            physicalMemoryGB: memoryGB,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func catalogModel(
        id: String,
        minRAM: Int?,
        size: Int64,
        type: String = "text"
    ) -> CLICatalogModel {
        CLICatalogModel(
            id: id,
            s3Name: id.replacingOccurrences(of: "/", with: "__"),
            displayName: id,
            modelType: type,
            sizeGb: Double(size) / 1_000_000_000,
            description: id,
            minRamGb: minRAM,
            family: nil,
            quantization: nil,
            maxContextLength: nil,
            capabilities: type == "embeddings" ? ["embeddings"] : ["text-generation"],
            totalSizeBytes: size
        )
    }

    private func localModel(id: String) -> CLILocalModelEntry {
        CLILocalModelEntry(
            id: id,
            modelType: "text",
            quantization: "4-bit",
            sizeBytes: 1_000,
            estimatedMemoryGb: 1
        )
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        // Full-package swift-testing runs >2,500 tests concurrently and can
        // starve the MainActor for several seconds on CI. Keep the production
        // poll intervals tiny in these tests, but don't make scheduler load a
        // behavioral failure.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private struct SnapshotCatalogCLI: ModelCatalogCLIRunning {
    let snapshot: ModelLibrarySnapshot

    func fetchSnapshot() async throws -> ModelLibrarySnapshot { snapshot }

    func downloadEvents(modelID _: String) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func removeModel(modelID _: String) async throws {}
}

private struct NoopSetupStartCLI: SetupStartCLIRunning {
    func start(modelID _: String) async throws {}
}

private final class ScriptedPreparationService: OnboardingPreparationServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [Result<OnboardingPreparationPlan, Error>]

    init(plans: [Result<OnboardingPreparationPlan, Error>]) {
        self.plans = plans
    }

    func fetchPlan() async throws -> OnboardingPreparationPlan {
        let result = lock.withLock { plans.isEmpty ? nil : plans.removeFirst() }
        guard let result else { throw OnboardingPreparationServiceError.noCompatibleModel }
        return try result.get()
    }

    func downloadEvents(modelID _: String) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func startProvider(modelID _: String) async throws {}
}

private final class RecordingProviderCLI: ProviderCLIRunning, @unchecked Sendable {
    struct Call: Equatable {
        let arguments: [String]
        let timeout: Duration
    }

    private let lock = NSLock()
    private var storage: [Call] = []
    var calls: [Call] { lock.withLock { storage } }

    func run(arguments: [String], timeout: Duration) async throws -> ProviderCLIResult {
        lock.withLock { storage.append(.init(arguments: arguments, timeout: timeout)) }
        return ProviderCLIResult(exitStatus: 0, stderrTail: "")
    }
}

private final class ProviderEvidenceBox: @unchecked Sendable {
    static let missing = OnboardingProviderEvidence(
        daemonState: nil,
        localEndpoint: nil,
        processIsAlive: false,
        localEndpointProcessIsAlive: false
    )

    private let lock = NSLock()
    private var storage: OnboardingProviderEvidence

    init(_ evidence: OnboardingProviderEvidence) {
        storage = evidence
    }

    func read() -> OnboardingProviderEvidence { lock.withLock { storage } }

    func set(_ evidence: OnboardingProviderEvidence) {
        lock.withLock { storage = evidence }
    }
}

private final class PreparationAttemptService: OnboardingPreparationServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let model: OnboardingModelChoice
    private var startResults: [Result<Void, Error>]
    private var downloadCallCount = 0
    private var startCallCount = 0

    init(
        model: OnboardingModelChoice,
        startResults: [Result<Void, Error>] = []
    ) {
        self.model = model
        self.startResults = startResults
    }

    var downloadCalls: Int { lock.withLock { downloadCallCount } }
    var startCalls: Int { lock.withLock { startCallCount } }

    func fetchPlan() async throws -> OnboardingPreparationPlan {
        OnboardingPreparationPlan(
            choices: [model],
            recommendedModelID: model.id,
            fetchedAt: .now
        )
    }

    func downloadEvents(modelID _: String) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
        lock.withLock { downloadCallCount += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield(.progress(file: "weights", bytes: model.sizeBytes, total: model.sizeBytes))
            continuation.yield(.done)
            continuation.finish()
        }
    }

    func startProvider(modelID _: String) async throws {
        let result: Result<Void, Error>? = lock.withLock {
            startCallCount += 1
            return startResults.isEmpty ? nil : startResults.removeFirst()
        }
        try result?.get()
    }
}

private enum PreparationAttemptError: Error, LocalizedError {
    case startFailed

    var errorDescription: String? { "Provider start failed. Retry start." }
}
