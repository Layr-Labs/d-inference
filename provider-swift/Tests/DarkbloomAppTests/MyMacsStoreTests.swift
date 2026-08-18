import Testing
@testable import DarkbloomApp

@Test("My Macs store fixtures keep all loading and account states distinct")
@MainActor
func myMacsStoreFixturesCoverRequiredStates() throws {
    let loading = MyMacsStore(fixture: .loading)
    guard case .loading = loading.availability else {
        Issue.record("Loading fixture should not masquerade as empty")
        return
    }
    #expect(loading.snapshot == nil)
    #expect(!loading.isEmpty)

    let ready = MyMacsStore(fixture: .ready)
    guard case .ready(_, .available) = ready.availability else {
        Issue.record("Ready fixture should include the account summary")
        return
    }
    #expect(ready.macs.count == 5)
    #expect(ready.snapshot?.accountSummary?.counts.total == 5)

    let partial = MyMacsStore(fixture: .partialSummary)
    guard case .ready(_, .unavailable(let message)) = partial.availability else {
        Issue.record("Summary failure should remain a partial ready state")
        return
    }
    #expect(message.contains("summary"))
    #expect(partial.macs.count == ready.macs.count)
    #expect(partial.snapshot?.accountSummary == nil)

    let empty = MyMacsStore(fixture: .empty)
    guard case .ready(_, .available) = empty.availability else {
        Issue.record("An empty account is still a successful load")
        return
    }
    #expect(empty.isEmpty)
    #expect(empty.snapshot?.accountSummary?.counts.total == 0)

    let signedOut = MyMacsStore(fixture: .signedOut)
    guard case .signedOut = signedOut.availability else {
        Issue.record("Signed-out state should not be an availability error")
        return
    }
    #expect(signedOut.snapshot == nil)
    #expect(!signedOut.isEmpty)

    let unavailable = MyMacsStore(fixture: .unavailable)
    guard case .unavailable = unavailable.availability else {
        Issue.record("Unavailable state should not masquerade as empty")
        return
    }
    #expect(unavailable.snapshot == nil)

    let stale = MyMacsStore(fixture: .staleRetained)
    guard case .staleRetained(let lastUpdated, let failedAt, _, .available) =
        stale.availability else {
        Issue.record("Refresh failure should retain and label prior data")
        return
    }
    #expect(failedAt > lastUpdated)
    #expect(stale.snapshot != nil)
    #expect(stale.macs == ready.macs)
}

@Test("Preview loading and retry transitions recover to ready inventory")
@MainActor
func myMacsStorePreviewTransitionsAreDeterministic() {
    let loading = MyMacsStore(fixture: .loading)
    loading.completePreviewLoad()
    guard case .ready = loading.availability else {
        Issue.record("Preview loading completion should produce ready inventory")
        return
    }
    #expect(!loading.macs.isEmpty)

    let unavailable = MyMacsStore(fixture: .unavailable)
    unavailable.retryPreviewLoad()
    guard case .ready = unavailable.availability else {
        Issue.record("Preview retry should produce ready inventory")
        return
    }
    #expect(!unavailable.macs.isEmpty)

    let signedOut = MyMacsStore(fixture: .signedOut)
    signedOut.retryPreviewLoad()
    guard case .signedOut = signedOut.availability else {
        Issue.record("Retry should not bypass account authentication")
        return
    }

    signedOut.signInPreview()
    guard case .ready(_, .available) = signedOut.availability else {
        Issue.record("The explicit preview sign-in action should recover account inventory")
        return
    }
    #expect(!signedOut.macs.isEmpty)
}

@Test("Account summary values remain coordinator-authored, not local recounts")
@MainActor
func myMacsSummaryPreservesCoordinatorCounts() throws {
    let snapshot = try #require(MyMacsStore(fixture: .ready).snapshot)
    let summary = try #require(snapshot.accountSummary)

    #expect(summary.counts.total == 5)
    #expect(summary.counts.serving == 1)
    #expect(summary.counts.online == 1)
    #expect(summary.counts.offline == 2)
    #expect(summary.counts.untrusted == 1)
    #expect(summary.counts.needingAttention == 3)
    #expect(summary.availableBalance == MicroUSD(12_850_000))
    #expect(summary.lifetimeJobs == 428)
}

@Test("Preview refresh retains inventory and clears stale refresh errors")
@MainActor
func myMacsPreviewRefreshRetainsSnapshot() throws {
    let store = MyMacsStore(fixture: .staleRetained)
    let originalMacs = store.macs
    let refreshDate = MyMacsFixtures.refreshFailureDate.addingTimeInterval(30)

    #expect(store.canRefreshPreview)
    store.refreshPreview(at: refreshDate)

    guard case .ready(let lastUpdated, .available) = store.availability else {
        Issue.record("Refresh should clear stale-retained state without discarding inventory")
        return
    }
    #expect(lastUpdated == refreshDate)
    #expect(store.snapshot?.asOf == refreshDate)
    #expect(store.macs == originalMacs)

    let signedOut = MyMacsStore(fixture: .signedOut)
    signedOut.refreshPreview(at: refreshDate)
    #expect(!signedOut.canRefreshPreview)
    guard case .signedOut = signedOut.availability else {
        Issue.record("Refresh must not bypass authentication")
        return
    }
}

@Test("Preview removal accepts only retained records and reconciles account counts")
@MainActor
func myMacsPreviewRemovalIsScopedAndConsistent() throws {
    let store = MyMacsStore(fixture: .ready)
    let originalSummary = try #require(store.snapshot?.accountSummary)
    let offline = try #require(store.macs.first { $0.lifecycle == .offline })
    let removalDate = MyMacsFixtures.referenceDate.addingTimeInterval(30)

    for mac in store.macs where !mac.canRemove {
        #expect(!store.removePreviewMac(id: mac.id, at: removalDate))
    }
    #expect(store.macs.count == 5)

    #expect(store.removePreviewMac(id: offline.id, at: removalDate))
    #expect(store.mac(id: offline.id) == nil)
    #expect(store.macs.count == 4)

    let summary = try #require(store.snapshot?.accountSummary)
    #expect(summary.counts.total == 4)
    #expect(summary.counts.offline == 1)
    #expect(summary.counts.serving == originalSummary.counts.serving)
    #expect(summary.counts.online == originalSummary.counts.online)
    #expect(summary.counts.untrusted == originalSummary.counts.untrusted)
    #expect(summary.counts.hardwareTrusted == 2)
    #expect(summary.counts.needingAttention == 2)
    #expect(summary.lifetimeEarnings == originalSummary.lifetimeEarnings)
    #expect(summary.lifetimeJobs == originalSummary.lifetimeJobs)
    #expect(summary.last24HoursEarnings == originalSummary.last24HoursEarnings)
    #expect(summary.last24HoursJobs == originalSummary.last24HoursJobs)

    guard case .ready(let lastUpdated, .available) = store.availability else {
        Issue.record("A local preview removal should leave the inventory ready")
        return
    }
    #expect(lastUpdated == removalDate)
    #expect(store.snapshot?.asOf == removalDate)
}

@Test("Preview removal remains available for never-seen records without serials")
@MainActor
func myMacsPreviewRemovalUsesSessionFallbackWithoutInventingIdentity() throws {
    let store = MyMacsStore(fixture: .ready)
    let neverSeen = try #require(store.macs.first { $0.lifecycle == .neverSeen })
    let originalLifetimeJobs = try #require(store.snapshot?.accountSummary?.lifetimeJobs)

    #expect(neverSeen.serialNumber == nil)
    #expect(neverSeen.removalToken == "preview-session-never-seen")
    #expect(store.removePreviewMac(
        id: neverSeen.id,
        at: MyMacsFixtures.referenceDate.addingTimeInterval(10)
    ))
    #expect(store.mac(id: neverSeen.id) == nil)
    #expect(store.snapshot?.accountSummary?.counts.offline == 1)
    #expect(store.snapshot?.accountSummary?.counts.needingAttention == 2)
    #expect(store.snapshot?.accountSummary?.lifetimeJobs == originalLifetimeJobs)
}
