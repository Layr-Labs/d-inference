import Foundation
import Testing
@testable import DarkbloomApp

// Live-mode My Macs: account-session persistence contract, callback parsing,
// session-expiry mapping, and store transitions mirroring the fixture states.
@Suite("Account session + live My Macs store transitions")
struct AccountSessionTests {
    // MARK: Stubs

    final class StubAccountSession: AccountSessionManaging, @unchecked Sendable {
        var token: String?
        var signInResult: Result<String, Error> = .failure(AccountSessionError.cancelled)
        var signInCallCount = 0
        var signOutCallCount = 0

        var isSignedIn: Bool { token != nil }
        func accessToken() -> String? { token }
        func signIn() async throws -> String {
            signInCallCount += 1
            let token = try signInResult.get()
            self.token = token
            return token
        }
        func signOut() {
            signOutCallCount += 1
            token = nil
        }
    }

    final class StubFleet: FleetServicing, @unchecked Sendable {
        var providersResult: Result<MyMacsProvidersWireResponse, Error>
        var summaryResult: Result<MyMacsSummaryWireResponse, Error>
        var deleteError: Error?
        private(set) var deleteCalls: [(removalToken: String, bearerToken: String)] = []
        private(set) var bearerTokensSeen: [String] = []

        init(
            providers: MyMacsProvidersWireResponse,
            summary: MyMacsSummaryWireResponse? = nil
        ) {
            providersResult = .success(providers)
            summaryResult = summary.map { .success($0) }
                ?? .failure(FleetClientError.httpError(statusCode: 500, detail: "summary down"))
        }

        func providers(bearerToken: String) async throws -> MyMacsProvidersWireResponse {
            bearerTokensSeen.append(bearerToken)
            return try providersResult.get()
        }

        func summary(bearerToken: String) async throws -> MyMacsSummaryWireResponse {
            bearerTokensSeen.append(bearerToken)
            return try summaryResult.get()
        }

        func deleteProvider(removalToken: String, bearerToken: String) async throws {
            deleteCalls.append((removalToken, bearerToken))
            if let deleteError { throw deleteError }
        }
    }

    final class InMemorySessionStore: AccountSessionStoring, @unchecked Sendable {
        var token: String?
        func loadToken() -> String? { token }
        func saveToken(_ token: String) -> Bool {
            self.token = token
            return true
        }
        func clearToken() { token = nil }
    }

    // MARK: Wire fixtures (minimal shapes matching me_handlers.go)

    static let referenceDate = Date(timeIntervalSince1970: 1_787_056_496)

    static func provider(
        id: String,
        status: String,
        serial: String?,
        failedChallenges: Int = 0
    ) -> MyMacsProviderWireRecord {
        MyMacsProviderWireRecord(
            providerID: id,
            accountID: "acct-1",
            status: status,
            online: status == "serving" || status == "online",
            lastHeartbeat: status == "offline" || status == "never_seen"
                ? nil
                : referenceDate.addingTimeInterval(-15),
            hardware: MyMacsHardwareWireRecord(
                machineModel: "MacBook Pro", chipName: "Apple M4 Max", chipFamily: "M4 Max",
                chipTier: nil, memoryGB: 64, memoryAvailableGB: nil,
                cpuCores: nil, gpuCores: 40, memoryBandwidthGBs: nil
            ),
            models: nil,
            backend: "mlx-swift",
            version: "0.8.1",
            serialNumber: serial,
            trustLevel: "hardware",
            attested: true,
            mdaVerified: true,
            seKeyBound: true,
            sePublicKey: "se-pubkey",
            providerKey: "x25519-pub",
            secureEnclave: true,
            sipEnabled: true,
            secureBootEnabled: true,
            authenticatedRootEnabled: true,
            runtimeVerified: true,
            lastChallengeVerified: referenceDate.addingTimeInterval(-60),
            failedChallenges: failedChallenges,
            systemMetrics: nil,
            backendCapacity: nil,
            warmModels: nil,
            currentModel: nil,
            pendingRequests: nil,
            maxConcurrency: nil,
            prefillTPS: nil,
            decodeTPS: nil,
            reputation: nil,
            lifetimeRequestsServed: 10,
            lifetimeTokensGenerated: 2_000,
            registeredAt: referenceDate.addingTimeInterval(-86_400),
            lastSeen: status == "never_seen" ? nil : referenceDate.addingTimeInterval(-15)
        )
    }

    static func providersWire() -> MyMacsProvidersWireResponse {
        MyMacsProvidersWireResponse(
            providers: [
                provider(id: "session-live-1", status: "serving", serial: "SERVESERIAL01"),
                provider(id: "session-off-1", status: "offline", serial: "OFFLINESERIAL1"),
            ],
            latestProviderVersion: "0.8.1",
            minimumProviderVersion: "0.7.5",
            heartbeatTimeoutSeconds: 90,
            challengeMaxAgeSeconds: 360
        )
    }

    static func summaryWire() -> MyMacsSummaryWireResponse {
        MyMacsSummaryWireResponse(
            accountID: "acct-1",
            availableBalanceMicroUSD: 500_000,
            withdrawableBalanceMicroUSD: 400_000,
            payoutReady: true,
            lifetimeMicroUSD: 2_000_000,
            lifetimeJobs: 42,
            last24hMicroUSD: 100_000,
            last24hJobs: 2,
            last7dMicroUSD: 700_000,
            last7dJobs: 14,
            counts: MyMacsFleetCountsWireRecord(
                total: 2, online: 0, serving: 1, offline: 1, untrusted: 0,
                hardware: 2, needsAttention: 1
            ),
            latestProviderVersion: "0.8.1",
            minimumProviderVersion: "0.7.5"
        )
    }

    @MainActor
    private func makeLiveStore(
        session: StubAccountSession,
        fleet: StubFleet
    ) -> MyMacsStore {
        MyMacsStore(session: session, fleet: fleet)
    }

    // MARK: Callback parsing

    @Test("The handoff callback parses only fragment-carried tokens")
    func callbackParsing() throws {
        // Canonical handoff.
        let parsed = try #require(AccountLinkCallback.parse(
            url: URL(string: "darkbloom://auth/callback#token=eyJhbGciOiJFUzI1NiJ9.x.y")!
        ))
        #expect(parsed.token == "eyJhbGciOiJFUzI1NiJ9.x.y")

        // Extra fragment params are tolerated; the token survives decoding.
        #expect(AccountLinkCallback.parse(
            url: URL(string: "darkbloom://auth/callback#src=x&token=a%2Fb%3Dc")!
        )?.token == "a/b=c")

        // Query-param tokens are REJECTED: the fragment-only policy is what
        // keeps bearer tokens out of server logs.
        #expect(AccountLinkCallback.parse(
            url: URL(string: "darkbloom://auth/callback?token=leaked-in-logs")!
        ) == nil)
        #expect(AccountLinkCallback.parse(url: URL(string: "darkbloom://auth/callback#token=")!) == nil)
        #expect(AccountLinkCallback.parse(url: URL(string: "darkbloom://auth/other#token=x")!) == nil)
        #expect(AccountLinkCallback.parse(url: URL(string: "darkbloom://evil/callback#token=x")!) == nil)
        #expect(AccountLinkCallback.parse(url: URL(string: "https://auth/callback#token=x")!) == nil)
        #expect(AccountLinkCallback.parse(url: URL(string: AccountLinkCallback.callbackURL)!) == nil)
    }

    // MARK: Keychain persistence contract

    @Test("Keychain contract names stay pinned with the Info.plist entitlement note")
    func keychainContractIsPinned() {
        // These names are persisted user state: renaming them orphans stored
        // sessions and desyncs the documented keychain-access-groups entry in
        // Resources/DarkbloomApp/Info.plist.
        #expect(KeychainSessionStore.service == "dev.darkbloom.app.privy-session")
        #expect(KeychainSessionStore.account == "privy-access-token")
        #expect(KeychainSessionStore.accessGroup == "dev.darkbloom.app.shared")
    }

    // MARK: Session check + refresh transitions

    @Test("start() resolves to signed-out when no token is persisted; to loading when one is")
    @MainActor
    func startSessionCheck() {
        let session = StubAccountSession()
        let store = makeLiveStore(session: session, fleet: StubFleet(providers: Self.providersWire()))

        store.start()
        guard case .signedOut = store.availability else {
            Issue.record("Missing token must surface the signed-out state, got \(store.availability)")
            return
        }
        #expect(store.snapshot == nil)
        #expect(!store.isEmpty)

        session.token = "fresh-token"
        let signedIn = makeLiveStore(session: session, fleet: StubFleet(providers: Self.providersWire()))
        signedIn.start()
        guard case .loading = signedIn.availability else {
            Issue.record("A persisted token should kick off the initial fetch")
            return
        }
        #expect(signedIn.mode == .live)
    }

    @Test("A successful refresh lands ready with coordinator counts intact")
    @MainActor
    func refreshSuccess() async throws {
        let session = StubAccountSession()
        session.token = "good-token"
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)
        let refreshDate = Self.referenceDate.addingTimeInterval(120)

        await store.refreshLive(at: refreshDate)

        guard case let .ready(lastUpdated, .available) = store.availability else {
            Issue.record("Successful fetch should land ready/summary-available, got \(store.availability)")
            return
        }
        #expect(lastUpdated == refreshDate)
        let snapshot = try #require(store.snapshot)
        #expect(snapshot.asOf == refreshDate)
        #expect(snapshot.macs.count == 2)
        #expect(snapshot.accountSummary?.counts.total == 2)
        #expect(snapshot.accountSummary?.lifetimeJobs == 42)
        #expect(Set(fleet.bearerTokensSeen) == ["good-token"])
    }

    @Test("Summary failure degrades to a partial ready state, never a hard error")
    @MainActor
    func refreshSummaryFailureIsPartial() async throws {
        let session = StubAccountSession()
        session.token = "good-token"
        let fleet = StubFleet(providers: Self.providersWire()) // summary stub fails
        let store = makeLiveStore(session: session, fleet: fleet)

        await store.refreshLive(at: Self.referenceDate)

        guard case let .ready(_, .unavailable(message)) = store.availability else {
            Issue.record("Summary 5xx must remain a partial ready state, got \(store.availability)")
            return
        }
        #expect(message == "Machine status is current, but the account summary is unavailable.")
        #expect(store.snapshot?.macs.count == 2)
        #expect(store.snapshot?.accountSummary == nil)
    }

    @Test("A refresh failure with inventory becomes stale-retained, mirroring the fixture")
    @MainActor
    func refreshFailureRetainsSnapshot() async throws {
        let session = StubAccountSession()
        session.token = "good-token"
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)

        // Land ready first…
        await store.refreshLive(at: Self.referenceDate)
        let originalMacs = store.macs
        // …then fail the refresh.
        fleet.providersResult = .failure(FleetClientError.unreachable("offline"))
        let failureDate = Self.referenceDate.addingTimeInterval(45)
        await store.refreshLive(at: failureDate)

        guard case let .staleRetained(lastUpdated, failedAt, message, .available) = store.availability else {
            Issue.record("Refresh failure should retain and label prior data, got \(store.availability)")
            return
        }
        #expect(lastUpdated == Self.referenceDate)
        #expect(failedAt == failureDate)
        #expect(message == "Refresh failed. Showing the last account snapshot.")
        #expect(store.macs == originalMacs)
        #expect(store.snapshot?.asOf == Self.referenceDate)
    }

    @Test("A first-load failure without inventory is unavailable, not empty")
    @MainActor
    func initialFailureIsUnavailable() async {
        let session = StubAccountSession()
        session.token = "good-token"
        let fleet = StubFleet(providers: Self.providersWire())
        fleet.providersResult = .failure(FleetClientError.httpError(statusCode: 500, detail: nil))
        let store = makeLiveStore(session: session, fleet: fleet)

        await store.refreshLive(at: Self.referenceDate)

        guard case let .unavailable(message) = store.availability else {
            Issue.record("A failed first load must not masquerade as inventory, got \(store.availability)")
            return
        }
        #expect(message == "Darkbloom could not load the Macs linked to this account.")
        #expect(store.snapshot == nil)
        #expect(!store.isEmpty)
    }

    // MARK: Session expiry mapping (401)

    @Test("A coordinator 401 signs the user out and drops the persisted token")
    @MainActor
    func refreshSessionExpiredSignsOut() async {
        let session = StubAccountSession()
        session.token = "expired-token"
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)

        await store.refreshLive(at: Self.referenceDate) // land ready
        fleet.providersResult = .failure(FleetClientError.sessionExpired)
        await store.refreshLive(at: Self.referenceDate.addingTimeInterval(30))

        guard case .signedOut = store.availability else {
            Issue.record("A 401 must collapse the session, got \(store.availability)")
            return
        }
        #expect(store.snapshot == nil)
        #expect(session.signOutCallCount == 1)
        #expect(session.token == nil) // no repeated 401 storms on next start()
    }

    @Test("Missing token on refresh resolves to signed-out without calling the session")
    @MainActor
    func refreshWithoutTokenIsSignedOut() async {
        let session = StubAccountSession()
        let fleet = StubFleet(providers: Self.providersWire())
        let store = makeLiveStore(session: session, fleet: fleet)

        await store.refreshLive(at: Self.referenceDate)

        guard case .signedOut = store.availability else {
            Issue.record("Missing token must not masquerade as a network error")
            return
        }
        #expect(fleet.bearerTokensSeen.isEmpty)
        #expect(session.signOutCallCount == 0)
    }

    // MARK: Sign-in handoff

    @Test("A completed handoff persists the token and fetches the fleet")
    @MainActor
    func signInSuccess() async {
        let session = StubAccountSession()
        session.signInResult = .success("new-privy-token")
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)

        await store.signInLive()

        #expect(session.signInCallCount == 1)
        #expect(session.token == "new-privy-token")
        #expect(!store.isSigningIn)
        #expect(store.signInErrorMessage == nil)
        guard case .ready = store.availability else {
            Issue.record("Post-handoff refresh should land ready, got \(store.availability)")
            return
        }
    }

    @Test("A dismissed auth browser stays signed out without an error")
    @MainActor
    func signInCancellationIsSilent() async {
        let session = StubAccountSession()
        let store = makeLiveStore(session: session, fleet: StubFleet(providers: Self.providersWire()))

        await store.signInLive()

        #expect(session.signInCallCount == 1)
        #expect(store.signInErrorMessage == nil)
        guard case .signedOut = store.availability else {
            Issue.record("Cancellation is a normal outcome, not a failure")
            return
        }
    }

    @Test("A failed handoff keeps the signed-out state with a visible message")
    @MainActor
    func signInFailureSurfacesMessage() async throws {
        let session = StubAccountSession()
        session.signInResult = .failure(AccountSessionError.browserFailed("TLS reset"))
        let store = makeLiveStore(session: session, fleet: StubFleet(providers: Self.providersWire()))

        await store.signInLive()

        let message = try #require(store.signInErrorMessage)
        #expect(message.contains("TLS reset"))
        #expect(!store.isSigningIn)
        guard case .signedOut = store.availability else {
            Issue.record("Sign-in failure must keep the signed-out state")
            return
        }
    }

    // MARK: Machine removal

    @Test("Removal hits the coordinator with the serial token before reconciling counts")
    @MainActor
    func removalSucceeds() async throws {
        let session = StubAccountSession()
        session.token = "token-1"
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)
        await store.refreshLive(at: Self.referenceDate)

        let offline = try #require(store.macs.first { $0.lifecycle == .offline })
        let removed = await store.removeMac(id: offline.id)

        #expect(removed)
        #expect(fleet.deleteCalls.count == 1)
        #expect(fleet.deleteCalls.first?.removalToken == "OFFLINESERIAL1")
        #expect(fleet.deleteCalls.first?.bearerToken == "token-1")
        #expect(store.mac(id: offline.id) == nil)
        #expect(store.macs.count == 1)
        #expect(store.snapshot?.accountSummary?.counts.total == 1)
        #expect(store.snapshot?.accountSummary?.counts.offline == 0)
        // Activity totals stay account-scoped (the coordinator preserves them).
        #expect(store.snapshot?.accountSummary?.lifetimeJobs == 42)
        // Timestamp advancement after removal is pinned by the
        // removePreviewMac tests in MyMacsStoreTests.
        guard case let .ready(_, .available) = store.availability else {
            Issue.record("Removal should leave the inventory ready, got \(store.availability)")
            return
        }
    }

    @Test("Removal of a live (non-removable) machine never reaches the coordinator")
    @MainActor
    func removalRejectsLiveMachines() async throws {
        let session = StubAccountSession()
        session.token = "token-1"
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)
        await store.refreshLive(at: Self.referenceDate)

        let serving = try #require(store.macs.first { $0.lifecycle == .serving })
        #expect(!(await store.removeMac(id: serving.id)))
        #expect(fleet.deleteCalls.isEmpty)
        #expect(store.macs.count == 2)
    }

    @Test("A removal rejected as online (409) retains inventory with a banner message")
    @MainActor
    func removalConflictRetainsInventory() async throws {
        let session = StubAccountSession()
        session.token = "token-1"
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)
        await store.refreshLive(at: Self.referenceDate)

        fleet.deleteError = FleetClientError.httpError(
            statusCode: 409,
            detail: "machine is currently online — stop it before removing"
        )
        let offline = try #require(store.macs.first { $0.lifecycle == .offline })
        #expect(!(await store.removeMac(id: offline.id)))

        guard case let .staleRetained(_, _, message, .available) = store.availability else {
            Issue.record("Removal failure should retain inventory, got \(store.availability)")
            return
        }
        #expect(message.contains("Could not remove"))
        #expect(message.contains("online"))
        #expect(store.macs.count == 2)
    }

    @Test("A 401 on removal collapses the session exactly like a 401 on fetch")
    @MainActor
    func removalSessionExpired() async throws {
        let session = StubAccountSession()
        session.token = "token-1"
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)
        await store.refreshLive(at: Self.referenceDate)

        fleet.deleteError = FleetClientError.sessionExpired
        let offline = try #require(store.macs.first { $0.lifecycle == .offline })
        #expect(!(await store.removeMac(id: offline.id)))

        guard case .signedOut = store.availability else {
            Issue.record("A 401 on DELETE must sign out, got \(store.availability)")
            return
        }
        #expect(session.signOutCallCount == 1)
        #expect(store.snapshot == nil)
    }

    @Test("Removal without a persisted session is refused before any network call")
    @MainActor
    func removalWithoutTokenIsSignedOut() async throws {
        let session = StubAccountSession()
        session.token = "token-1"
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)
        await store.refreshLive(at: Self.referenceDate)

        session.token = nil // externally revoked
        let offline = try #require(store.macs.first { $0.lifecycle == .offline })
        #expect(!(await store.removeMac(id: offline.id)))
        #expect(fleet.deleteCalls.isEmpty)
        guard case .signedOut = store.availability else {
            Issue.record("Tokenless removal should not run, got \(store.availability)")
            return
        }
    }

    // MARK: Sign-out + mode dispatch

    @Test("signOut clears the persisted token and collapses the account view")
    @MainActor
    func signOutClearsSession() async {
        let session = StubAccountSession()
        session.token = "token-1"
        let fleet = StubFleet(providers: Self.providersWire(), summary: Self.summaryWire())
        let store = makeLiveStore(session: session, fleet: fleet)
        await store.refreshLive(at: Self.referenceDate)
        #expect(store.snapshot != nil)

        store.signOut()

        guard case .signedOut = store.availability else {
            Issue.record("Sign-out must collapse to the signed-out state")
            return
        }
        #expect(store.snapshot == nil)
        #expect(session.signOutCallCount == 1)
        #expect(session.token == nil)
    }

    @Test("Mode dispatch: fixture stores keep synchronous preview behavior through the shared API")
    @MainActor
    func modeDispatchKeepsFixturesDeterministic() async {
        let fixture = MyMacsStore(fixture: .signedOut)
        #expect(fixture.mode == .fixture)

        fixture.signIn()
        guard case .ready = fixture.availability else {
            Issue.record("Fixture sign-in must stay a synchronous preview transition")
            return
        }

        let removed = await fixture.removeMac(
            id: fixture.macs.first { $0.canRemove }!.id
        )
        #expect(removed)

        // Live stores report their mode and never collide with preview APIs.
        let live = MyMacsStore(
            session: StubAccountSession(),
            fleet: StubFleet(providers: Self.providersWire())
        )
        #expect(live.mode == .live)
        live.signOut() // must not touch preview fixtures
        guard case .signedOut = live.availability else {
            Issue.record("Live sign-out collapses the account view")
            return
        }
    }
}
