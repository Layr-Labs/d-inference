import Foundation
import Testing
@testable import DarkbloomApp

@Suite("My Macs account-bound operations")
@MainActor
struct MyMacsLiveOperationTests {
    @Test("Replacing an account cannot retain the old account after a failed refresh")
    func replacementAccountClearsRetainedSnapshot() async throws {
        let (session, fleet, store) = makeStore()
        await store.refreshLive(at: AccountSessionTests.referenceDate)
        #expect(store.snapshot != nil)
        session.token = "replacement-account"
        fleet.providersResult = .failure(FleetClientError.httpError(statusCode: 503, detail: "unavailable"))

        await store.refreshLive()

        #expect(store.snapshot == nil)
        #expect(!store.isRefreshing)
        guard case .unavailable = store.availability else {
            Issue.record("Another account's snapshot must not become a retained fallback")
            return
        }
    }

    @Test("A pending confirmation cannot remove a record after an intervening refresh")
    func confirmationIsBoundToPresentedRevision() async throws {
        let (_, fleet, store) = makeStore()
        await store.refreshLive()
        let offline = try #require(store.macs.first { $0.canRemove })
        let presentedRevision = store.actionRevision
        await store.refreshLive()

        #expect(await store.removeMac(id: offline.id, expectedRevision: presentedRevision) == false)
        #expect(fleet.deleteCalls.isEmpty)
        #expect(store.mac(id: offline.id) != nil)
    }

    @Test("Old-account records cannot be deleted with a replacement account's token")
    func removalRejectsSnapshotFromAnotherSession() async throws {
        let (session, fleet, store) = makeStore()
        await store.refreshLive()
        let offline = try #require(store.macs.first { $0.canRemove })
        session.token = "replacement-account"

        #expect(await store.removeMac(id: offline.id) == false)
        #expect(fleet.deleteCalls.isEmpty)
        #expect(store.snapshot == nil)
        #expect(store.removingMacID == nil)
    }

    @Test("A successful removal does not claim that other fleet reports were refreshed")
    func removalPreservesReportTimestampAndAccountPrecision() async throws {
        let (_, fleet, store) = makeStore()
        await store.refreshLive(at: AccountSessionTests.referenceDate)
        let offline = try #require(store.macs.first { $0.canRemove })
        let original = try #require(store.snapshot)

        #expect(await store.removeMac(id: offline.id))
        #expect(fleet.deleteCalls.first?.removalToken == offline.providerID)
        #expect(store.snapshot?.asOf == original.asOf)
        #expect(store.snapshot?.accountSummary?.lifetimeEarnings == original.accountSummary?.lifetimeEarnings)
        #expect(store.snapshot?.accountSummary?.lifetimeJobs == original.accountSummary?.lifetimeJobs)
        #expect(store.removingMacID == nil)
    }

    @Test("Removing one retained Mac does not dismiss an earlier refresh failure")
    func removalPreservesStaleWarning() async throws {
        let (_, fleet, store) = makeStore()
        await store.refreshLive(at: AccountSessionTests.referenceDate)
        fleet.providersResult = .failure(FleetClientError.httpError(statusCode: 503, detail: "unavailable"))
        await store.refreshLive()
        let offline = try #require(store.macs.first { $0.canRemove })
        let staleState = store.availability

        #expect(await store.removeMac(id: offline.id))
        #expect(store.availability == staleState)
        #expect(store.snapshot?.asOf == AccountSessionTests.referenceDate)
    }

    @Test("A successful retry clears only the removal error")
    func removalRetryClearsItsError() async throws {
        let (_, fleet, store) = makeStore()
        await store.refreshLive(at: AccountSessionTests.referenceDate)
        let offline = try #require(store.macs.first { $0.canRemove })
        fleet.deleteError = FleetClientError.httpError(statusCode: 409, detail: "still connected")
        #expect(await store.removeMac(id: offline.id) == false)
        #expect(store.removalErrorMessage != nil)
        #expect(store.removingMacID == nil)
        fleet.deleteError = nil

        #expect(await store.removeMac(id: offline.id))
        #expect(store.removalErrorMessage == nil)
        #expect(store.snapshot?.asOf == AccountSessionTests.referenceDate)
    }

    @Test("A late DELETE response cannot overwrite a newer refresh")
    func removalCompletionCannotCrossRefresh() async throws {
        let session = AccountSessionTests.StubAccountSession()
        session.token = "account-token"
        let fleet = PendingMyMacsRemovalFleet()
        let store = MyMacsStore(session: session, fleet: fleet)
        await store.refreshLive(at: AccountSessionTests.referenceDate)
        let offline = try #require(store.macs.first { $0.canRemove })
        let removal = Task { await store.removeMac(id: offline.id) }
        #expect(await fleet.waitForRemoval())
        #expect(store.removingMacID == offline.id)
        #expect(!store.canRefresh)
        await store.refreshLive(at: AccountSessionTests.referenceDate.addingTimeInterval(5))
        await fleet.completeRemoval()

        #expect(await removal.value == false)
        #expect(store.mac(id: offline.id) != nil)
        #expect(store.removingMacID == nil)
    }

    @Test("Sign-out wins a pending DELETE, including its progress state")
    func signOutWinsRemoval() async throws {
        let session = AccountSessionTests.StubAccountSession()
        session.token = "account-token"
        let fleet = PendingMyMacsRemovalFleet()
        let store = MyMacsStore(session: session, fleet: fleet)
        await store.refreshLive()
        let offline = try #require(store.macs.first { $0.canRemove })
        let removal = Task { await store.removeMac(id: offline.id) }
        #expect(await fleet.waitForRemoval())
        try store.signOut()
        await fleet.completeRemoval()

        #expect(await removal.value == false)
        #expect(store.snapshot == nil)
        #expect(store.removingMacID == nil)
        #expect(store.availability == .signedOut)
    }

    private func makeStore() -> (AccountSessionTests.StubAccountSession, AccountSessionTests.StubFleet, MyMacsStore) {
        let session = AccountSessionTests.StubAccountSession()
        session.token = "account-token"
        let fleet = AccountSessionTests.StubFleet(
            providers: AccountSessionTests.providersWire(), summary: AccountSessionTests.summaryWire()
        )
        return (session, fleet, MyMacsStore(session: session, fleet: fleet))
    }
}

private actor PendingMyMacsRemovalFleet: FleetServicing {
    private var continuation: CheckedContinuation<Void, Never>?

    func providers(bearerToken _: String) async throws -> MyMacsProvidersWireResponse {
        AccountSessionTests.providersWire()
    }

    func summary(bearerToken _: String) async throws -> MyMacsSummaryWireResponse {
        AccountSessionTests.summaryWire()
    }

    func deleteProvider(removalToken _: String, bearerToken _: String) async throws {
        await withCheckedContinuation { continuation = $0 }
    }

    func completeRemoval() {
        continuation?.resume()
        continuation = nil
    }

    func waitForRemoval() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if continuation != nil { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return continuation != nil
    }
}
