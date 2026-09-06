import Testing
@testable import DarkbloomApp

@Suite("Diagnostic product action dispatch")
@MainActor
struct DiagnosticActionDispatchTests {
    @Test("Finish Setup waits for sheet dismissal and dispatches once")
    func setupAfterDismissal() async throws {
        let (store, _) = try await scannedDiagnosticActionStore(
            checkID: "trust.trust-level", section: "trust", advice: "Run darkbloom enroll."
        )
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        #expect(dispatcher.presentation(for: fix, in: store, callbacks: recorder.callbacks).title == "Finish Setup")

        #expect(dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss) == nil)
        #expect(recorder.events == ["dismiss"])
        #expect(dispatcher.pendingFix == fix)
        #expect(store.selectedFixID == fix.id)

        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.events == ["dismiss", "setup"])
        #expect(dispatcher.pendingFix == nil)
        #expect(store.selectedFixID == nil)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.events == ["dismiss", "setup"])
        #expect(store.report.prioritizedFixes == [fix])
    }

    @Test("Restart enters the shell request/confirmation seam after dismissal")
    func restartRequestsConfirmation() async throws {
        let (store, _) = try await scannedDiagnosticActionStore()
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        let snapshot = recorder.providerStore.snapshot
        recorder.onRequest = {
            #expect(dispatcher.pendingFix == nil)
            #expect(store.selectedFixID == nil)
        }

        #expect(dispatcher.presentation(for: fix, in: store, callbacks: recorder.callbacks).title == "Restart")
        _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        #expect(recorder.providerRequests.isEmpty)
        #expect(recorder.confirmation == nil)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)

        #expect(recorder.events == ["dismiss", "request-provider"])
        #expect(recorder.providerRequests == [.restart])
        #expect(recorder.confirmation?.action == .restart)
        #expect(recorder.confirmation?.message.contains("interrupt active work") == true)
        #expect(recorder.providerStore.snapshot == snapshot)
        #expect(recorder.providerStore.pendingAction == nil)
        // Cancel/no acceptance: repeated dismissal must not request or run it.
        recorder.confirmation = nil
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.providerRequests == [.restart])
        #expect(recorder.providerStore.snapshot == snapshot)
    }

    @Test("Network Settings uses only the system pane deep link after dismissal")
    func networkSettingsUsesInjectedOpener() async throws {
        let (store, _) = try await scannedDiagnosticActionStore(
            checkID: "coordinator", section: "connectivity", advice: "Check the connection."
        )
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        #expect(recorder.networkCommands.arguments.isEmpty)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.events == ["dismiss", "network"])
        #expect(recorder.networkCommands.arguments == [[
            "x-apple.systempreferences:com.apple.preference.network"
        ]])
    }

    @Test("Opening a model repair navigates without changing selection or weights", arguments: [
        ("traffic.model-fits-in-ram", "traffic"),
        ("runtime.recent-model-load", "runtime"),
    ])
    func modelRepairOpensLibrary(checkID: String, section: String) async throws {
        let (store, _) = try await scannedDiagnosticActionStore(
            checkID: checkID, section: section, advice: "Choose a model that fits this Mac."
        )
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        let modelID = try #require(recorder.modelLibrary.models.first?.id)
        recorder.modelLibrary.selectModel(id: modelID)
        let models = recorder.modelLibrary.models
        #expect(dispatcher.presentation(for: fix, in: store, callbacks: recorder.callbacks).title == "Open Model Library")
        _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        #expect(recorder.events == ["dismiss"])
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.events == ["dismiss", "models"])
        #expect(recorder.modelLibrary.selectedModelID == modelID)
        #expect(recorder.modelLibrary.models == models)
        #expect(recorder.providerRequests.isEmpty)
    }

    @Test("Check for Updates reruns doctor in the sheet and uses its new report")
    func updateCheckRescansDoctor() async throws {
        let (store, cli) = try await scannedDiagnosticActionStore(
            checkID: "version.provider", section: "version", advice: "Install the new version, then restart."
        )
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        cli.mode = .payload(DoctorJSONReport(
            schema: 1, version: "0.8.16", checks: [], fixes: [],
            verdict: .init(status: "pass", failures: 0, warnings: 0)
        ))
        #expect(dispatcher.presentation(for: fix, in: store, callbacks: recorder.callbacks).title == "Check for Updates")
        #expect(dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss) == nil)
        #expect(store.isScanning)
        #expect(dispatcher.pendingFix == nil)
        #expect(recorder.events.isEmpty)
        try await waitForDiagnosticActionScan(store)
        #expect(cli.callCount == 2)
        #expect(store.report.prioritizedFixes.isEmpty)
        #expect(store.report.overallVerdict == .healthy)
        #expect(recorder.events.isEmpty)
    }

    @Test("Security and support retain manual guidance even when advice mentions restart", arguments: [
        ("security.sip", "security", "View Instructions"),
        ("billing.usage-reporting", "billing", "View Guidance"),
    ])
    func guidanceHasNoEffects(checkID: String, section: String, title: String) async throws {
        let advice = section == "security"
            ? "Restart into Recovery and review the security instructions."
            : "Review the logs and contact support if needed."
        let (store, _) = try await scannedDiagnosticActionStore(checkID: checkID, section: section, advice: advice)
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        #expect(dispatcher.presentation(for: fix, in: store, callbacks: recorder.callbacks).title == title)
        #expect(dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss) == fix)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.events.isEmpty)
        #expect(recorder.networkCommands.arguments.isEmpty)
        #expect(!store.simulateResolution(fixID: fix.id))
        #expect(store.report.prioritizedFixes == [fix])
    }
}
