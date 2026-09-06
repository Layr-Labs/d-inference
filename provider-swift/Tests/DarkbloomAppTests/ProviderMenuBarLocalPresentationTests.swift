import Testing
@testable import DarkbloomApp

@Test("Discovered endpoints never grant menu ownership", arguments: LocalAPIFixture.allCases)
func menuBarDiscoveredEndpointHasNoEndAction(_ fixture: LocalAPIFixture) {
    let presentation = ProviderMenuBarLocalPresentation(
        state: LocalAPIFixtures.make(fixture),
        startState: .idle,
        hasActiveSession: false,
        isLive: true
    )

    #expect(!presentation.showsEndSession)
    #expect(!presentation.canEndSession)
}

@Test("A responding provider endpoint is described as external, not an owned session")
func menuBarProviderEndpointIsIndependent() {
    let presentation = ProviderMenuBarLocalPresentation(
        state: LocalAPIFixtures.make(.active),
        startState: .idle,
        hasActiveSession: false,
        isLive: true
    )

    #expect(presentation.title == "Endpoint responding")
    #expect(presentation.detail.contains("Managed outside Studio"))
    #expect(presentation.detail.contains("network provider"))
    #expect(!presentation.canEndSession)
}

@Test("An owned ready session exposes End session only with ownership")
func menuBarOwnedReadySessionCanEnd() {
    let state = LocalAPIFixtures.make(.directOnly)
    let startState = LocalAPIStartState.ready(modelID: LocalAPIFixtures.sampleModelIDs[0])
    let owned = ProviderMenuBarLocalPresentation(
        state: state, startState: startState, hasActiveSession: true, isLive: true
    )
    let released = ProviderMenuBarLocalPresentation(
        state: state, startState: startState, hasActiveSession: false, isLive: true
    )

    #expect(owned.title == "Local session ready")
    #expect(owned.canEndSession)
    #expect(!released.showsEndSession)
    #expect(!released.canEndSession)
}

@Test("Owned readiness does not conceal failed or incomplete endpoint probes", arguments: [
    LocalAPIFixture.unreachable, .healthChecking, .modelCatalogUnavailable, .noCompatibleModels, .stopped,
])
func menuBarOwnedReadinessRequiresEndpoint(_ fixture: LocalAPIFixture) {
    let presentation = ProviderMenuBarLocalPresentation(
        state: LocalAPIFixtures.make(fixture),
        startState: .ready(modelID: LocalAPIFixtures.sampleModelIDs[0]),
        hasActiveSession: true,
        isLive: true
    )

    #expect(presentation.title == "Checking local session")
    #expect(presentation.tone != .active)
    #expect(presentation.canEndSession)
}

@Test("Waiting and failed local starts retain their owned End action", arguments: [
    LocalAPIStartState.starting(modelID: "model"),
    .waitingForEndpoint(modelID: "model"),
    .failed(.readinessTimedOut(modelID: "model")),
    .failed(.shutdownTimedOut),
])
func menuBarUnreadyOwnedSessionCanEnd(_ state: LocalAPIStartState) {
    let presentation = ProviderMenuBarLocalPresentation(
        state: LocalAPIFixtures.make(.stopped),
        startState: state,
        hasActiveSession: true,
        isLive: true
    )

    #expect(presentation.showsEndSession)
    #expect(presentation.canEndSession)
    #expect(presentation.tone != .active)
}

@Test("An ending session keeps ownership but disables repeat cancellation")
func menuBarEndingSessionIsBusy() {
    let presentation = ProviderMenuBarLocalPresentation(
        state: LocalAPIFixtures.make(.directOnly),
        startState: .cancelling,
        hasActiveSession: true,
        isLive: true
    )

    #expect(presentation.showsEndSession)
    #expect(!presentation.canEndSession)
    #expect(presentation.isBusy)
}

@Test("Preview data cannot grant an End session action")
func menuBarPreviewCannotEndSession() {
    let presentation = ProviderMenuBarLocalPresentation(
        state: LocalAPIFixtures.make(.directOnly),
        startState: .ready(modelID: LocalAPIFixtures.sampleModelIDs[0]),
        hasActiveSession: true,
        isLive: false
    )

    #expect(presentation.isSample)
    #expect(presentation.detail.contains("preview"))
    #expect(!presentation.showsEndSession)
    #expect(!presentation.canEndSession)
    #expect(!presentation.isBusy)
}
