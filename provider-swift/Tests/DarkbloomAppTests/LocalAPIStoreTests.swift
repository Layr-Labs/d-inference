import Foundation
import Testing
@testable import DarkbloomApp

@Test("Local API fixtures cover running, stopped, exposed, and failed discovery")
@MainActor
func localAPIFixturesCoverEdgeStates() throws {
    let active = LocalAPIStore(fixture: .active)
    let activeEndpoint = try #require(active.endpoint)
    #expect(activeEndpoint.mode == .unified)
    #expect(activeEndpoint.bindScope == .thisMac)
    #expect(activeEndpoint.requiresAuthentication)
    #expect(activeEndpoint.health == .reachable)
    #expect(activeEndpoint.availableModelIDs?.count == 2)

    let direct = LocalAPIStore(fixture: .directOnly)
    #expect(direct.endpoint?.mode == .directOnly)

    let starting = LocalAPIStore(fixture: .starting)
    guard case .starting = starting.state else {
        Issue.record("Starting fixture must remain distinct from ready")
        return
    }

    let stopped = LocalAPIStore(fixture: .stopped)
    guard case .stopped = stopped.state else {
        Issue.record("Stopped fixture must not advertise an endpoint")
        return
    }

    let exposed = LocalAPIStore(fixture: .networkExposed)
    #expect(exposed.endpoint?.bindScope == .allInterfaces)

    let emptyCatalog = LocalAPIStore(fixture: .noCompatibleModels)
    #expect(emptyCatalog.endpoint?.availableModelIDs == [])

    let portCollision = LocalAPIStore(fixture: .portCollision)
    guard case .unavailable(let message) = portCollision.state else {
        Issue.record("Port collision must be an actionable unavailable state")
        return
    }
    #expect(message.contains("8000"))

    let failed = LocalAPIStore(fixture: .unreachable)
    #expect(failed.endpoint?.health == .unreachable)
    failed.retryPreviewHealth()
    #expect(failed.endpoint?.health == .reachable)

    let unavailableCatalog = LocalAPIStore(fixture: .modelCatalogUnavailable)
    #expect(unavailableCatalog.endpoint?.modelCatalog == .failed)
    unavailableCatalog.retryPreviewModelCatalog()
    #expect(unavailableCatalog.endpoint?.availableModelIDs == LocalAPIFixtures.sampleModelIDs)

    let checking = LocalAPIStore(fixture: .healthChecking)
    #expect(checking.endpoint?.health == .checking)
}

@Test("Loopback access scope covers the IPv4 loopback range")
func localAPILoopbackScopeIsNotLimitedToOneAddress() {
    #expect(LocalAPIBindScope(host: "127.0.0.1") == .thisMac)
    #expect(LocalAPIBindScope(host: "127.42.0.9") == .thisMac)
    #expect(LocalAPIBindScope(host: "::1") == .thisMac)
    #expect(LocalAPIBindScope(host: "0.0.0.0") == .allInterfaces)
    #expect(LocalAPIBindScope(host: "100.64.0.2") == .network)
}

@Test("Local API presentation keeps mode, access, and probe truth distinct")
func localAPIPresentationDoesNotInferMissingRuntimeData() {
    #expect(LocalAPIPresentation.modeTitle(nil) == "Mode not reported")
    #expect(LocalAPIPresentation.modeTitle(.unified) == "Local + network")
    #expect(LocalAPIPresentation.accessDetail(.allInterfaces).contains("without built-in TLS"))
    #expect(LocalAPIPresentation.availableModelSummary(.loading) == "Checking…")
    #expect(LocalAPIPresentation.availableModelSummary(.failed) == "Unavailable")
    #expect(LocalAPIPresentation.availableModelSummary(.available([])) == "None")
    #expect(LocalAPIPresentation.authenticationDetail(requiresAuthentication: true)
        .contains("inference request"))
}

@Test("Local API keys begin hidden and auth-disabled endpoints cannot reveal one")
@MainActor
func localAPISecretDisclosureIsExplicit() {
    let active = LocalAPIStore(fixture: .active)
    #expect(!active.isAPIKeyRevealed)
    active.setAPIKeyRevealed(true)
    #expect(active.isAPIKeyRevealed)
    active.hideAPIKey()
    #expect(!active.isAPIKeyRevealed)

    let open = LocalAPIStore(fixture: .authDisabled)
    open.setAPIKeyRevealed(true)
    #expect(!open.isAPIKeyRevealed)
    #expect(open.text(for: .apiKey) == nil)
}

@Test("Code examples use the live base URL without embedding the API key")
@MainActor
func localAPICodeExamplesKeepSecretsOutOfSnippets() throws {
    let store = LocalAPIStore(fixture: .active)
    let endpoint = try #require(store.endpoint)
    let curl = try #require(store.text(for: .code(.curl)))
    let python = try #require(store.text(for: .code(.python)))

    #expect(curl.contains("\(endpoint.baseURL.absoluteString)/chat/completions"))
    #expect(curl.contains("-H \"Authorization: Bearer $OPENAI_API_KEY\""))
    #expect(!curl.contains("'Authorization: Bearer $OPENAI_API_KEY'"))
    #expect(python.contains("os.environ[\"OPENAI_API_KEY\"]"))
    #expect(!curl.contains(endpoint.apiKey ?? ""))
    #expect(!python.contains(endpoint.apiKey ?? ""))
}

@Test("Auth-disabled examples omit the Authorization header")
@MainActor
func localAPIOpenExampleOmitsAuthentication() throws {
    let store = LocalAPIStore(fixture: .authDisabled)
    let curl = try #require(store.text(for: .code(.curl)))

    #expect(!curl.contains("Authorization"))
    #expect(!curl.contains("OPENAI_API_KEY"))
}

@Test("Copy confirmations are transient store state")
@MainActor
func localAPICopyFeedbackCanBeCleared() {
    let store = LocalAPIStore(fixture: .active)
    store.markCopied(.baseURL)
    #expect(store.lastCopiedItem == .baseURL)
    store.clearCopyConfirmation()
    #expect(store.lastCopiedItem == nil)
}

@Test("Stopped-state commands match the two CLI serve modes")
@MainActor
func localAPIStartCommandsMatchCLI() {
    let store = LocalAPIStore(fixture: .stopped)
    #expect(store.text(for: .command(.unified)) == "darkbloom start --local-endpoint")
    #expect(store.text(for: .command(.directOnly)) == "darkbloom start --local")
}
