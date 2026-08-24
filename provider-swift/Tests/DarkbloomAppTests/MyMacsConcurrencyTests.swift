import Foundation
import Testing
@testable import DarkbloomApp

@Suite("My Macs live request ordering")
struct MyMacsConcurrencyTests {
    @Test("A late older refresh cannot replace a newer account snapshot")
    @MainActor
    func newerRefreshWinsOutOfOrderCompletion() async throws {
        let session = MutableAccountSession(token: "account-token")
        let fleet = OutOfOrderFleet()
        let store = MyMacsStore(session: session, fleet: fleet)
        let olderDate = Date(timeIntervalSince1970: 1_000)
        let newerDate = Date(timeIntervalSince1970: 2_000)

        let older = Task { await store.refreshLive(at: olderDate) }
        #expect(await fleet.waitForProviderCalls(1))
        let newer = Task { await store.refreshLive(at: newerDate) }
        #expect(await fleet.waitForProviderCalls(2))

        await fleet.succeedProviderCall(1, with: Self.providers(id: "newer"))
        await newer.value
        #expect(store.snapshot?.macs.map(\.providerID) == ["newer"])
        #expect(store.snapshot?.asOf == newerDate)

        await fleet.succeedProviderCall(0, with: Self.providers(id: "older"))
        await older.value
        #expect(store.snapshot?.macs.map(\.providerID) == ["newer"])
        #expect(store.snapshot?.asOf == newerDate)
    }

    @Test("Sign-out invalidates an in-flight refresh even when transport ignores cancellation")
    @MainActor
    func signOutWinsPendingRefresh() async {
        let session = MutableAccountSession(token: "account-token")
        let fleet = OutOfOrderFleet()
        let store = MyMacsStore(session: session, fleet: fleet)

        let pending = Task {
            await store.refreshLive(at: Date(timeIntervalSince1970: 1_000))
        }
        #expect(await fleet.waitForProviderCalls(1))

        store.signOut()
        await fleet.succeedProviderCall(0, with: Self.providers(id: "stale"))
        await pending.value

        #expect(session.accessToken() == nil)
        #expect(store.snapshot == nil)
        guard case .signedOut = store.availability else {
            Issue.record("A completed stale request must not resurrect signed-out data")
            return
        }
    }

    @Test("A response is bound to the token that started its refresh")
    @MainActor
    func refreshCannotCrossSessionReplacement() async {
        let session = MutableAccountSession(token: "old-account-token")
        let fleet = OutOfOrderFleet()
        let store = MyMacsStore(session: session, fleet: fleet)

        let pending = Task {
            await store.refreshLive(at: Date(timeIntervalSince1970: 1_000))
        }
        #expect(await fleet.waitForProviderCalls(1))
        session.token = "replacement-account-token"
        await fleet.succeedProviderCall(0, with: Self.providers(id: "wrong-account"))
        await pending.value

        #expect(store.snapshot == nil)
        guard case .loading = store.availability else {
            Issue.record("A response from the previous session must not publish")
            return
        }
    }

    @Test("Refresh entry points cancel and supersede their prior scheduled task")
    @MainActor
    func scheduledRefreshSupersedesPriorTask() async {
        let session = MutableAccountSession(token: "account-token")
        let fleet = OutOfOrderFleet()
        let store = MyMacsStore(session: session, fleet: fleet)

        store.refresh()
        #expect(await fleet.waitForProviderCalls(1))
        store.retry()
        #expect(await fleet.waitForProviderCalls(2))

        await fleet.succeedProviderCall(1, with: Self.providers(id: "retry"))
        #expect(await eventually {
            store.snapshot?.macs.map(\.providerID) == ["retry"]
        })
        await fleet.succeedProviderCall(0, with: Self.providers(id: "refresh"))
        #expect(await eventually { await fleet.pendingProviderCalls == 0 })
        #expect(store.snapshot?.macs.map(\.providerID) == ["retry"])
    }

    @Test("A 401 that completes sign-in clears progress and leaves a retryable signed-out state")
    @MainActor
    func signInSessionExpiryClearsProgress() async {
        let session = MutableAccountSession(token: "new-account-token")
        let fleet = OutOfOrderFleet()
        let store = MyMacsStore(session: session, fleet: fleet)

        let signIn = Task { await store.signInLive() }
        #expect(await fleet.waitForProviderCalls(1))
        #expect(store.isSigningIn)

        await fleet.failProviderCall(0, with: FleetClientError.sessionExpired)
        await signIn.value

        #expect(!store.isSigningIn)
        #expect(session.accessToken() == nil)
        guard case .signedOut = store.availability else {
            Issue.record("An expired sign-in session must remain retryable")
            return
        }
    }

    private static func providers(id: String) -> MyMacsProvidersWireResponse {
        MyMacsProvidersWireResponse(
            providers: [
                AccountSessionTests.provider(
                    id: id,
                    status: "offline",
                    serial: "\(id.uppercased())-SERIAL"
                ),
            ],
            latestProviderVersion: "0.8.1",
            minimumProviderVersion: "0.7.5",
            heartbeatTimeoutSeconds: 90,
            challengeMaxAgeSeconds: 360
        )
    }

    @MainActor
    private func eventually(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
}

private final class MutableAccountSession: AccountSessionManaging, @unchecked Sendable {
    var token: String?

    init(token: String?) {
        self.token = token
    }

    var isSignedIn: Bool { token != nil }
    func accessToken() -> String? { token }
    func signIn() async throws -> String {
        guard let token else { throw AccountSessionError.cancelled }
        return token
    }
    func signOut() {
        token = nil
    }
}

private actor OutOfOrderFleet: FleetServicing {
    private var nextCall = 0
    private var providerContinuations:
        [Int: CheckedContinuation<MyMacsProvidersWireResponse, any Error>] = [:]

    var pendingProviderCalls: Int { providerContinuations.count }

    func providers(bearerToken _: String) async throws -> MyMacsProvidersWireResponse {
        let call = nextCall
        nextCall += 1
        return try await withCheckedThrowingContinuation { continuation in
            providerContinuations[call] = continuation
        }
    }

    func summary(bearerToken _: String) async throws -> MyMacsSummaryWireResponse {
        throw FleetClientError.httpError(statusCode: 503, detail: "summary unavailable")
    }

    func deleteProvider(removalToken _: String, bearerToken _: String) async throws {}

    func succeedProviderCall(
        _ call: Int,
        with response: MyMacsProvidersWireResponse
    ) {
        providerContinuations.removeValue(forKey: call)?.resume(returning: response)
    }

    func failProviderCall(_ call: Int, with error: FleetClientError) {
        providerContinuations.removeValue(forKey: call)?.resume(throwing: error)
    }

    func waitForProviderCalls(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if nextCall >= expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nextCall >= expected
    }
}
