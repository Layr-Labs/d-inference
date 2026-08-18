import Testing
@testable import DarkbloomApp

@Test("Contribution scope filters the privacy-safe ledger to this Mac")
@MainActor
func contributionScopeFiltersLedger() throws {
    let store = ContributionsStore(fixture: .active)
    let snapshot = try #require(store.snapshot)

    #expect(store.scope == .thisMac)
    #expect(!store.filteredLedger.isEmpty)
    #expect(store.filteredLedger.allSatisfy {
        $0.providerKey == snapshot.currentProviderKey
    })
    #expect(Set(store.filteredLedger.map(\.providerID)).count > 1)
    let thisMacCount = store.filteredLedger.count
    let thisMacTokens = store.shownRecordsTokenCount

    store.setScope(.allMacs)
    #expect(store.filteredLedger.count > thisMacCount)
    #expect(store.filteredLedger.contains {
        $0.providerKey != snapshot.currentProviderKey
    })
    #expect(store.shownRecordsTokenCount > thisMacTokens)
    #expect(zip(store.filteredLedger, store.filteredLedger.dropFirst()).allSatisfy {
        $0.timestamp >= $1.timestamp
    })
}

@Test("Empty and unavailable fixtures remain distinct")
@MainActor
func emptyAndUnavailableContributionsRemainDistinct() throws {
    let empty = ContributionsStore(fixture: .empty)
    guard case .available = empty.availability else {
        Issue.record("The empty fixture should still be successfully available")
        return
    }
    #expect(empty.snapshot != nil)
    #expect(empty.isEmpty)
    #expect(empty.filteredLedger.isEmpty)
    #expect(empty.shownRecordsTokenCount == 0)
    let emptyPulsePreview = try #require(empty.pulsePreview)
    #expect(emptyPulsePreview.points.count == 7)
    #expect(emptyPulsePreview.points.allSatisfy { $0.amount == .zero && $0.jobs == 0 })

    let unavailable = ContributionsStore(fixture: .unavailable)
    guard case .unavailable = unavailable.availability else {
        Issue.record("The unavailable fixture should not masquerade as an empty account")
        return
    }
    #expect(unavailable.snapshot == nil)
    #expect(!unavailable.isEmpty)
    #expect(unavailable.filteredLedger.isEmpty)
    #expect(unavailable.validatePayout(MicroUSD(1_000_000)) == .unavailable)

    unavailable.retryPreviewLoad()
    guard case .available = unavailable.availability else {
        Issue.record("The deterministic preview retry should restore sample data")
        return
    }
    #expect(unavailable.snapshot != nil)
    #expect(unavailable.pulsePreview != nil)
}

@Test("Payout validation follows readiness, minimum, balance, and lifecycle")
@MainActor
func payoutValidationCoversAllGuards() throws {
    let notReady = ContributionsStore(fixture: .payoutNotReady)
    #expect(notReady.validatePayout(MicroUSD(1_000_000)) == .setupRequired)

    let store = ContributionsStore(fixture: .active)
    let snapshot = try #require(store.snapshot)
    #expect(snapshot.minimumPayout == MicroUSD(1_000_000))
    #expect(store.validatePayout(.zero) == .nonPositive)
    #expect(store.validatePayout(MicroUSD(999_999)) == .belowMinimum(
        minimum: MicroUSD(1_000_000)
    ))
    #expect(store.validatePayout(MicroUSD(7_500_001)) == .exceedsWithdrawable(
        withdrawable: MicroUSD(7_500_000)
    ))
    #expect(store.validatePayout(MicroUSD(1_000_000)) == nil)

    #expect(store.requestPreviewPayout(amount: MicroUSD(1_000_000)) == .accepted(
        PreviewPayoutRequest(
            id: "preview-payout-001",
            requestedAt: ContributionsFixtures.previewPayoutTimestamp,
            amount: MicroUSD(1_000_000)
        )
    ))
    #expect(store.validatePayout(MicroUSD(1_000_000)) == .alreadySubmitting)
}

@Test("A preview payout preserves authoritative balances and updates only local history")
@MainActor
func previewPayoutLifecycleKeepsAccountingSemanticsSeparate() throws {
    let store = ContributionsStore(fixture: .active, initialScope: .allMacs)
    let before = try #require(store.snapshot)

    #expect(store.requestPreviewPayout(amount: MicroUSD(1_500_000)) == .accepted(
        PreviewPayoutRequest(
            id: "preview-payout-001",
            requestedAt: ContributionsFixtures.previewPayoutTimestamp,
            amount: MicroUSD(1_500_000)
        )
    ))
    let receipt = try #require(store.advancePreviewPayout())
    let after = try #require(store.snapshot)

    #expect(receipt.id == "preview-payout-001")
    #expect(receipt.completedAt == receipt.requestedAt.addingTimeInterval(5))
    #expect(after.availableBalance == before.availableBalance)
    #expect(after.withdrawableBalance == before.withdrawableBalance)
    #expect(after.earnedLifetime == before.earnedLifetime)
    #expect(after.lifetimeJobs == before.lifetimeJobs)
    #expect(after.records == before.records)
    #expect(store.previewPayoutHistory == [receipt])
    #expect(store.previewPayoutState == .completed(receipt))

    store.acknowledgeCompletedPreviewPayout()
    #expect(store.previewPayoutState == .idle)
}

@Test("Cancelling a preview request leaves authoritative balances untouched")
@MainActor
func previewPayoutCancellationIsNonMutating() throws {
    let store = ContributionsStore(fixture: .active)
    let before = try #require(store.snapshot)

    _ = store.requestPreviewPayout(amount: MicroUSD(1_000_000))
    store.cancelPreviewPayout()

    #expect(store.previewPayoutState == .idle)
    #expect(store.snapshot == before)
    #expect(store.previewPayoutHistory.isEmpty)
}

@Test("Payout errors can be dismissed without changing balances")
@MainActor
func payoutErrorsAreDismissible() throws {
    let store = ContributionsStore(fixture: .active)
    let balance = try #require(store.snapshot?.withdrawableBalance)

    #expect(store.requestPreviewPayout(amount: MicroUSD(1)) == .rejected(
        .belowMinimum(minimum: MicroUSD(1_000_000))
    ))
    #expect(store.payoutError == .belowMinimum(minimum: MicroUSD(1_000_000)))
    #expect(store.snapshot?.withdrawableBalance == balance)

    store.dismissPayoutError()
    #expect(store.payoutError == nil)
}
