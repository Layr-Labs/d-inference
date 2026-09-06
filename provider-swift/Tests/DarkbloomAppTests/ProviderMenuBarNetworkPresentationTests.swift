import Testing
@testable import DarkbloomApp

@Test("A running unverified provider is not presented as sharing or routable", arguments: [
    ProviderTrustState.pending, .failed, .unknown,
])
func menuBarRunningProviderNeedsVerification(_ trust: ProviderTrustState) {
    var snapshot = ProviderPreviewScenario.online.snapshot
    snapshot.trust.state = trust
    let presentation = ProviderMenuBarNetworkPresentation(snapshot: snapshot)

    #expect(presentation.tone != .active)
    #expect(presentation.title != "Handling requests")
    #expect(presentation.title != "Sharing compute")
    #expect(presentation.detail.lowercased().contains("running") || presentation.detail.contains("Verification"))
}

@Test("Verified idle provider still does not claim active sharing")
func menuBarVerifiedIdleProviderIsOnlyRunning() {
    let presentation = ProviderMenuBarNetworkPresentation(snapshot: ProviderPreviewScenario.online.snapshot)

    #expect(presentation.title == "Network provider running")
    #expect(presentation.detail.contains("No active inference"))
    #expect(presentation.tone != .active)
}

@Test("Active inference does not invent network-only request attribution")
func menuBarServingProviderHandlesRequests() {
    let presentation = ProviderMenuBarNetworkPresentation(snapshot: ProviderPreviewScenario.serving.snapshot)

    #expect(presentation.title == "Handling requests")
    #expect(presentation.detail.contains("local and network"))
}

@Test("Old running state cannot claim current activity")
func menuBarStaleRunningProviderIsUnknown() {
    var snapshot = ProviderPreviewScenario.serving.snapshot
    snapshot.sourceUpdatedAt = snapshot.sampledAt.addingTimeInterval(-120)
    let presentation = ProviderMenuBarNetworkPresentation(snapshot: snapshot)

    #expect(presentation.title == "Sharing status unknown")
    #expect(presentation.tone == .attention)
}

@Test("Confirmed paused state takes precedence over old report timestamps")
func menuBarPausedProviderStaysPaused() {
    var snapshot = ProviderPreviewScenario.online.snapshot
    snapshot.runState = .paused
    snapshot.sourceUpdatedAt = snapshot.sampledAt.addingTimeInterval(-120)

    #expect(ProviderMenuBarNetworkPresentation(snapshot: snapshot).title == "Network sharing paused")
}

@Test("Network replacement actions are blocked for the entire owned local lifetime", arguments: [
    ProviderAction.start, .restart,
])
func menuBarNetworkReplacementActionsRespectLocalOwnership(_ action: ProviderAction) {
    #expect(ProviderMenuBarActionPresentation.isBlocked(action, hasActiveLocalSession: true))
    #expect(!ProviderMenuBarActionPresentation.isBlocked(action, hasActiveLocalSession: false))
}

@Test("Local ownership does not prevent network pause or inspection", arguments: [
    ProviderAction.stop, .refresh, .runDiagnostics,
])
func menuBarLocalOwnershipAllowsNetworkInspection(_ action: ProviderAction) {
    #expect(!ProviderMenuBarActionPresentation.isBlocked(action, hasActiveLocalSession: true))
}

@Test("Menu preserves the provider confirmation policy", arguments: ProviderAction.allCases)
func menuBarNetworkConfirmationPolicy(_ action: ProviderAction) {
    let snapshot = ProviderPreviewScenario.serving.snapshot
    let existing = ProviderActionConfirmation(action: action, snapshot: snapshot)
    let menu = ProviderMenuBarActionConfirmation(action: action, snapshot: snapshot)

    #expect((menu != nil) == (existing != nil))
}

@Test("Pause and restart confirmations identify network sharing and affected local endpoint", arguments: [
    ProviderAction.stop, .restart,
])
func menuBarNetworkConfirmationNamesAffectedRuntime(_ action: ProviderAction) {
    let confirmation = ProviderMenuBarActionConfirmation(
        action: action, snapshot: ProviderPreviewScenario.serving.snapshot
    )

    #expect(confirmation?.title.contains("network sharing") == true)
    #expect(confirmation?.message.contains("Active requests may be interrupted") == true)
    #expect(confirmation?.message.contains("network provider and its local endpoint") == true)
    #expect(confirmation?.buttonTitle.contains("sharing") == true)
}

@Test("Pausing network sharing remains persistent across restarts")
func menuBarNetworkPauseIsPersistent() {
    let confirmation = ProviderMenuBarActionConfirmation(
        action: .stop, snapshot: ProviderPreviewScenario.online.snapshot
    )

    #expect(confirmation?.message.contains("stays paused across restarts") == true)
}
