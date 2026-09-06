import Testing
@testable import DarkbloomApp

@Suite("Diagnostic product action guards")
@MainActor
struct DiagnosticActionGuardTests {
    @Test("Every fixture fix stays simulated even when live callbacks are supplied", arguments: DiagnosticsFixture.allCases)
    func fixturesNeverDispatch(fixture: DiagnosticsFixture) throws {
        let store = DiagnosticsStore(fixture: fixture)
        let recorder = DiagnosticActionRecorder()
        // A fixture restart must still be available for simulation.
        recorder.hasActiveLocalSession = true
        recorder.needsSetup = true
        for fix in store.report.prioritizedFixes {
            let dispatcher = DiagnosticActionDispatcher()
            let presentation = dispatcher.presentation(for: fix, in: store, callbacks: recorder.callbacks)
            #expect(presentation.title == "Preview Fix")
            #expect(presentation.isEnabled)
            #expect(dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss) == fix)
            #expect(dispatcher.pendingFix == nil)
            #expect(store.simulateResolution(fixID: fix.id))
            try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        }
        #expect(recorder.events.isEmpty)
        #expect(recorder.providerRequests.isEmpty)
        #expect(recorder.networkCommands.arguments.isEmpty)
    }

    @Test("Preview shell never dispatches even if accidentally paired with a live store")
    func previewShellBlocksLiveCallbacks() async throws {
        let (store, cli) = try await scannedDiagnosticActionStore()
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        recorder.isPreview = true
        #expect(dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss) == fix)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.events.isEmpty)
        #expect(cli.callCount == 1)
        #expect(!store.simulateResolution(fixID: fix.id))
    }

    @Test("Restart is disabled for local ownership, incomplete setup, and provider transitions", arguments: [
        (true, false, ProviderRunState.serving),
        (false, true, .serving),
        (false, false, .starting),
        (false, false, .stopping),
        (false, false, .restarting),
    ])
    func ineligibleRestartDoesNotQueue(localSession: Bool, needsSetup: Bool, state: ProviderRunState) async throws {
        let (store, _) = try await scannedDiagnosticActionStore()
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder(providerState: state)
        recorder.hasActiveLocalSession = localSession
        recorder.needsSetup = needsSetup
        let presentation = dispatcher.presentation(for: fix, in: store, callbacks: recorder.callbacks)
        #expect(!presentation.isEnabled)
        #expect(presentation.disabledReason != nil)
        #expect(dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss) == nil)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(dispatcher.pendingFix == nil)
        #expect(recorder.events.isEmpty)
        #expect(store.launchedFixIDs.isEmpty)
    }

    @Test("Dismissal rechecks local ownership, setup, and preview state", arguments: ["local", "setup", "preview"])
    func eligibilityChangesDuringDismissal(guardName: String) async throws {
        let (store, _) = try await scannedDiagnosticActionStore()
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        switch guardName {
        case "local": recorder.hasActiveLocalSession = true
        case "setup": recorder.needsSetup = true
        default: recorder.isPreview = true
        }
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.events == ["dismiss"])
        #expect(recorder.providerRequests.isEmpty)
        #expect(recorder.confirmation == nil)
        #expect(dispatcher.pendingFix == nil)
    }

    @Test("Provider actions in flight block restart at both dispatch boundaries", arguments: [false, true])
    func pendingProviderActionBlocksRestart(queueBeforeRefresh: Bool) async throws {
        let (store, _) = try await scannedDiagnosticActionStore()
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let service = DiagnosticHoldingProviderRuntime()
        let provider = ProviderStore(service: service, initialSnapshot: ProviderPreviewScenario.serving.snapshot)
        let recorder = DiagnosticActionRecorder(providerStore: provider)
        if queueBeforeRefresh {
            _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        }
        let refresh = Task { await provider.refresh() }
        defer { Task { await service.release() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while provider.pendingAction == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.pendingAction == .refresh)
        #expect(provider.snapshot.runState == .serving)
        #expect(!dispatcher.presentation(for: fix, in: store, callbacks: recorder.callbacks).isEnabled)
        if !queueBeforeRefresh {
            _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        }
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.events == (queueBeforeRefresh ? ["dismiss"] : []))
        #expect(recorder.providerRequests.isEmpty)
        #expect(recorder.confirmation == nil)
        await service.release()
        await refresh.value
        #expect(provider.canPerform(.restart))
    }

    @Test("Scanning and stale fix cards cannot dispatch")
    func scanningAndStaleCardsAreInert() async throws {
        let (store, cli) = try await scannedDiagnosticActionStore()
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        let changedFix = DiagnosticFix(
            id: fix.id, title: fix.title, detail: "Outdated advice", priority: fix.priority,
            action: .openNetworkSettings
        )
        #expect(dispatcher.open(changedFix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss) == nil)
        cli.mode = .hang
        store.startScan()
        #expect(dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss) == nil)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        store.cancelScan()
        #expect(recorder.events.isEmpty)
        #expect(store.launchedFixIDs.isEmpty)
    }

    @Test("A superseding doctor report invalidates a queued fix")
    func supersededPendingFixDoesNotDispatch() async throws {
        let (store, cli) = try await scannedDiagnosticActionStore()
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        cli.mode = .payload(DoctorJSONReport(
            schema: 1, version: "0.8.16", checks: [], fixes: [],
            verdict: .init(status: "pass", failures: 0, warnings: 0)
        ))
        store.startScan()
        try await waitForDiagnosticActionScan(store)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.events == ["dismiss"])
        #expect(dispatcher.pendingFix == nil)
        #expect(recorder.providerRequests.isEmpty)
    }

    @Test("Duplicate clicks cannot replace a queued action or double-dispatch it")
    func duplicateClicksAreInert() async throws {
        let (store, _) = try await scannedDiagnosticActionStore()
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        #expect(recorder.events == ["dismiss"])
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.providerRequests == [.restart])
    }

    @Test("A Settings open failure reaches the shell without retrying on another dismissal")
    func networkFailureIsSurfaced() async throws {
        let (store, _) = try await scannedDiagnosticActionStore(
            checkID: "coordinator", section: "connectivity", advice: "Check the connection."
        )
        let fix = try #require(store.primaryFix)
        let dispatcher = DiagnosticActionDispatcher()
        let recorder = DiagnosticActionRecorder()
        recorder.networkCommands.shouldFail = true
        _ = dispatcher.open(fix, in: store, callbacks: recorder.callbacks, dismiss: recorder.dismiss)
        #expect(throws: DiagnosticsCLIError.self) {
            try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        }
        #expect(dispatcher.pendingFix == nil)
        try dispatcher.didDismiss(store: store, callbacks: recorder.callbacks)
        #expect(recorder.networkCommands.arguments.count == 1)
    }
}
