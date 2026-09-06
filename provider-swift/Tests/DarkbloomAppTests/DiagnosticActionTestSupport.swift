import Foundation
import Testing
@testable import DarkbloomApp

/// All effects are recorded in memory. Even the network-pane callback uses
/// the production opener with an injected command, never /usr/bin/open.
@MainActor
final class DiagnosticActionRecorder {
    let providerStore: ProviderStore
    let modelLibrary = ModelLibraryStore(fixture: .ready)
    let networkCommands = DiagnosticNetworkCommandRecorder()
    var isPreview = false
    var needsSetup = false
    var hasActiveLocalSession = false
    var events: [String] = []
    var providerRequests: [ProviderAction] = []
    var confirmation: ProviderActionConfirmation?
    var onRequest: (() -> Void)?

    init(providerState: ProviderRunState = .serving, providerStore: ProviderStore? = nil) {
        var snapshot = ProviderPreviewScenario.serving.snapshot
        snapshot.runState = providerState
        self.providerStore = providerStore ?? ProviderStore(
            service: PreviewProviderRuntimeService(scenario: .serving),
            initialSnapshot: snapshot
        )
    }

    var callbacks: DiagnosticActionCallbacks {
        DiagnosticActionCallbacks(
            isPreview: isPreview,
            restartUnavailableReason: DiagnosticActionCallbacks.restartUnavailableReason(
                providerStore: providerStore,
                needsSetup: needsSetup,
                hasActiveLocalSession: hasActiveLocalSession
            ),
            onContinueSetup: { self.events.append("setup") },
            requestProviderAction: { action in
                self.events.append("request-provider")
                self.providerRequests.append(action)
                // Observe the request/confirmation seam; do not perform the
                // action. The shell owns acceptance and its final guard check.
                self.confirmation = ProviderActionConfirmation(
                    action: action, snapshot: self.providerStore.snapshot
                )
                self.onRequest?()
            },
            openModelLibrary: { modelID in
                if let modelID { self.modelLibrary.selectModel(id: modelID) }
                self.events.append("models")
            },
            openNetworkSettings: {
                self.events.append("network")
                let commands = self.networkCommands
                try DiagnosticNetworkSettings.open(using: { try commands.record($0) })
            }
        )
    }

    func dismiss() { events.append("dismiss") }
}

final class DiagnosticNetworkCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var fail = false
    var shouldFail: Bool {
        get { lock.withLock { fail } }
        set { lock.withLock { fail = newValue } }
    }

    var arguments: [[String]] { lock.withLock { recorded } }

    func record(_ arguments: [String]) throws {
        lock.withLock { recorded.append(arguments) }
        if shouldFail { throw DiagnosticsCLIError.launchFailed("Settings unavailable") }
    }
}

func diagnosticActionPayload(
    checkID: String,
    section: String,
    advice: String
) -> DoctorJSONReport {
    DoctorJSONReport(
        schema: 1,
        version: "0.8.16",
        checks: [.init(
            id: checkID, section: section, title: "Check \(checkID)",
            status: "warn", detail: "Needs attention", advice: advice
        )],
        fixes: [.init(
            id: "fix-\(checkID)", check: checkID, title: "Review \(checkID)",
            detail: advice, priority: "recommended"
        )],
        verdict: .init(status: "warn", failures: 0, warnings: 1)
    )
}

@MainActor
func scannedDiagnosticActionStore(
    checkID: String = "runtime.daemon",
    section: String = "runtime",
    advice: String = "Restart the provider."
) async throws -> (DiagnosticsStore, StubDiagnosticsCLI) {
    let cli = StubDiagnosticsCLI(mode: .payload(diagnosticActionPayload(
        checkID: checkID, section: section, advice: advice
    )))
    let store = DiagnosticsStore(cli: cli)
    store.beginScanIfIdle()
    try await waitForDiagnosticActionScan(store)
    return (store, cli)
}

@MainActor
func waitForDiagnosticActionScan(_ store: DiagnosticsStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.isScanning && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!store.isScanning)
}

/// A refresh held in memory keeps ProviderStore.pendingAction set without
/// changing its run state. This exercises the separate in-flight-action gate.
actor DiagnosticHoldingProviderRuntime: ProviderRuntimeServicing {
    let snapshot = ProviderPreviewScenario.serving.snapshot
    private var completion: CheckedContinuation<Void, Never>?
    private var released = false

    func currentSnapshot() -> ProviderSnapshot { snapshot }

    func updates() -> AsyncStream<ProviderSnapshot> {
        AsyncStream { $0.finish() }
    }

    func perform(_ action: ProviderAction) async -> ProviderSnapshot {
        if !released {
            await withCheckedContinuation { completion = $0 }
        }
        return snapshot
    }

    func release() {
        released = true
        completion?.resume()
        completion = nil
    }
}
