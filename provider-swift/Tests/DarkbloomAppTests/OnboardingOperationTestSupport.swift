import Foundation
import ProviderCoreFoundation
@testable import DarkbloomApp

/// Explicit handshakes, deliberately insensitive to cancellation so tests can
/// release superseded work after its replacement is already running.
actor OnboardingOperationTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

actor OnboardingOperationTestPreparation: OnboardingPreparationServicing {
    let model: OnboardingModelChoice
    private var streams: [AsyncThrowingStream<ModelDownloadStreamEvent, Error>]
    private let startEntered: [OnboardingOperationTestGate]
    private let startRelease: [OnboardingOperationTestGate]
    private(set) var downloadedModelIDs: [String] = []
    private(set) var startedModelIDs: [String] = []

    init(
        model: OnboardingModelChoice,
        streams: [AsyncThrowingStream<ModelDownloadStreamEvent, Error>] = [],
        startEntered: [OnboardingOperationTestGate] = [],
        startRelease: [OnboardingOperationTestGate] = []
    ) {
        self.model = model
        self.streams = streams
        self.startEntered = startEntered
        self.startRelease = startRelease
    }

    func fetchPlan() async throws -> OnboardingPreparationPlan {
        .init(choices: [model], recommendedModelID: model.id, fetchedAt: .now)
    }

    func downloadEvents(modelID: String) async throws -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
        downloadedModelIDs.append(modelID)
        guard !streams.isEmpty else { throw OnboardingOperationTestError.unexpectedDownload }
        return streams.removeFirst()
    }

    func startProvider(modelID: String) async throws {
        let attempt = startedModelIDs.count
        startedModelIDs.append(modelID)
        if startEntered.indices.contains(attempt) { await startEntered[attempt].open() }
        if startRelease.indices.contains(attempt) { await startRelease[attempt].wait() }
    }
}

final class OnboardingOperationTestAccountRunner: AccountLinkRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [AsyncThrowingStream<AccountLinkEvent, Error>]

    init(streams: [AsyncThrowingStream<AccountLinkEvent, Error>]) {
        self.streams = streams
    }

    func linkEvents() -> AsyncThrowingStream<AccountLinkEvent, Error> {
        lock.withLock {
            guard !streams.isEmpty else {
                return AsyncThrowingStream { $0.finish(throwing: OnboardingOperationTestError.unexpectedAccountLink) }
            }
            return streams.removeFirst()
        }
    }
}

enum OnboardingOperationTestError: Error {
    case unexpectedDownload
    case unexpectedAccountLink
    case diagnosticsUnavailable
}

struct OnboardingOperationTestDiagnostics: DiagnosticsCLIRunning {
    var fails = false
    var enrolled = true

    func runDoctorJSON() async throws -> DoctorJSONReport {
        if fails { throw OnboardingOperationTestError.diagnosticsUnavailable }
        let ids = [
            "hardware", "metal-gpu", "macos", "attestationKey.se-key-sign-test",
            "sip", "authenticated-root", "account-link", "mdm-enrollment",
        ]
        return DoctorJSONReport(
            schema: 1,
            version: "test",
            checks: ids.map {
                .init(id: $0, section: "test", title: $0,
                      status: $0 == "mdm-enrollment" && !enrolled ? "fail" : "pass",
                      detail: $0 == "mdm-enrollment" && !enrolled ? "not enrolled" : "Verified test prerequisite",
                      advice: nil)
            },
            fixes: nil,
            verdict: .init(status: "pass", failures: 0, warnings: 0)
        )
    }
}

final class OnboardingOperationTestEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OnboardingProviderEvidence

    init(_ value: OnboardingProviderEvidence) { self.value = value }
    func read() -> OnboardingProviderEvidence { lock.withLock { value } }
    func set(_ value: OnboardingProviderEvidence) { lock.withLock { self.value = value } }

    static var missing: OnboardingProviderEvidence {
        .init(daemonState: nil, localEndpoint: nil, processIsAlive: false, localEndpointProcessIsAlive: false)
    }

    static func running(modelID: String, trusted: Bool = true) -> OnboardingProviderEvidence {
        let now = Date(timeIntervalSince1970: 2_000)
        let identity = ProcessIdentity(pid: 4242, startTimeMicros: 1)
        return OnboardingProviderEvidence(
            daemonState: DaemonState(
                pid: identity.pid, processIdentity: identity, version: "test",
                writtenAt: now.timeIntervalSince1970, startedAt: now.timeIntervalSince1970 - 1,
                trust: .init(trustLevel: trusted ? "hardware" : "self_signed", status: trusted ? "online" : "pending",
                             reason: "Test evidence", receivedAt: now.timeIntervalSince1970),
                currentModel: modelID, warmModels: [modelID]
            ),
            localEndpoint: LocalEndpointInfo(
                host: "127.0.0.1", port: 18080, apiKey: "test", version: "test",
                pid: identity.pid, processIdentity: identity, updatedAt: "test"
            ),
            processIsAlive: true, localEndpointProcessIsAlive: true, sampledAt: now
        )
    }
}

enum OnboardingOperationTestFixture {
    static func model(installed: Bool) -> OnboardingModelChoice {
        .init(id: "test/resumable-model", displayName: "Resumable model", summary: "Test only",
              sizeBytes: 1_000, minimumMemoryGB: 8, isInstalled: installed,
              runtimeEligibility: .init(status: .eligible, reason: "Test runtime"))
    }

    @MainActor
    static func flow(
        step: OnboardingStep = .preparation,
        service: any OnboardingPreparationServicing,
        account: (any AccountLinkRunning)? = nil,
        evidence: OnboardingOperationTestEvidence? = nil,
        diagnostics: OnboardingOperationTestDiagnostics = .init()
    ) -> OnboardingFlowModel {
        let evidence = evidence ?? OnboardingOperationTestEvidence(OnboardingOperationTestEvidence.missing)
        let flow = OnboardingFlowModel(
            startingAt: step,
            diagnosticsRunner: diagnostics,
            readinessFactsProvider: {
                .init(isAppleSilicon: true, physicalMemoryBytes: 32 * 1_073_741_824,
                      availableStorageBytes: 100 * 1_073_741_824)
            },
            accountLinkRunner: account, enrollmentRunner: nil, preparationService: service,
            verificationURLHandler: { _ in }, providerEvidenceProvider: evidence.read
        )
        flow.readinessPhase = .ready
        flow.readinessCompletedCount = OnboardingFlowModel.readinessItemCount
        flow.accountPhase = step == .account ? .introduction : .linked
        flow.enrollmentPhase = .profileDetected
        return flow
    }
}
