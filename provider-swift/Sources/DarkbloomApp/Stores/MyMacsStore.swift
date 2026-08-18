import Foundation
import Observation

enum MyMacsFixture: String, CaseIterable, Sendable {
    case loading
    case ready
    case partialSummary = "partial-summary"
    case empty
    case signedOut = "signed-out"
    case unavailable
    case staleRetained = "stale-retained"
}

enum MyMacsSummaryAvailability: Equatable, Sendable {
    case available
    case unavailable(message: String)
}

enum MyMacsAvailability: Equatable, Sendable {
    case loading
    case ready(lastUpdated: Date, summary: MyMacsSummaryAvailability)
    case signedOut
    case unavailable(message: String)
    case staleRetained(
        lastUpdated: Date,
        failedAt: Date,
        message: String,
        summary: MyMacsSummaryAvailability
    )
}

@MainActor
@Observable
final class MyMacsStore {
    private(set) var availability: MyMacsAvailability
    private(set) var snapshot: MyMacsSnapshot?

    init(fixture: MyMacsFixture = .ready) {
        let state = MyMacsFixtures.make(fixture)
        availability = state.availability
        snapshot = state.snapshot
    }

    var macs: [MyMac] {
        snapshot?.macs ?? []
    }

    var isEmpty: Bool {
        guard snapshot != nil else { return false }
        return macs.isEmpty
    }

    var canRefreshPreview: Bool {
        switch availability {
        case .ready, .staleRetained:
            snapshot != nil
        case .loading, .signedOut, .unavailable:
            false
        }
    }

    func mac(id: String) -> MyMac? {
        macs.first { $0.id == id }
    }

    /// Deterministic UI-preview transition for loading-state evaluations.
    func completePreviewLoad() {
        guard case .loading = availability else { return }
        apply(MyMacsFixtures.make(.ready))
    }

    /// Deterministic UI-preview recovery until coordinator requests are injected.
    func retryPreviewLoad() {
        guard case .unavailable = availability else { return }
        apply(MyMacsFixtures.make(.ready))
    }

    /// Deterministic UI-preview sign-in until account authentication is wired.
    func signInPreview() {
        guard case .signedOut = availability else { return }
        apply(MyMacsFixtures.make(.ready))
    }

    /// Removes only a coordinator-removable retained record from the local UI
    /// preview. Earnings and job history remain account-scoped, so this updates
    /// inventory counts but intentionally leaves activity totals untouched.
    @discardableResult
    func removePreviewMac(id: String, at requestedDate: Date = .now) -> Bool {
        guard var snapshot,
              let index = snapshot.macs.firstIndex(where: { $0.id == id }),
              snapshot.macs[index].canRemove,
              snapshot.macs[index].removalToken != nil
        else {
            return false
        }

        let previousDate: Date
        let summaryAvailability: MyMacsSummaryAvailability
        switch availability {
        case let .ready(lastUpdated, summary):
            previousDate = lastUpdated
            summaryAvailability = summary
        case let .staleRetained(lastUpdated, _, _, summary):
            previousDate = lastUpdated
            summaryAvailability = summary
        case .loading, .signedOut, .unavailable:
            return false
        }

        let removed = snapshot.macs.remove(at: index)
        if var summary = snapshot.accountSummary {
            summary.counts.total = max(0, summary.counts.total - 1)
            summary.counts.offline = max(0, summary.counts.offline - 1)
            if removed.trust.level == .hardware {
                summary.counts.hardwareTrusted = max(0, summary.counts.hardwareTrusted - 1)
            }
            if removed.attention.requiresAttention {
                summary.counts.needingAttention = max(0, summary.counts.needingAttention - 1)
            }
            snapshot.accountSummary = summary
        }

        let updatedAt = max(requestedDate, previousDate.addingTimeInterval(1))
        snapshot.asOf = updatedAt
        self.snapshot = snapshot
        availability = .ready(lastUpdated: updatedAt, summary: summaryAvailability)
        return true
    }

    /// Deterministic UI-only refresh until coordinator requests are injected.
    /// It keeps the last inventory, advances its timestamp, and clears a stale
    /// refresh failure without changing authentication or hard-error states.
    func refreshPreview(at requestedDate: Date = .now) {
        guard var snapshot else { return }

        let previousDate: Date
        let summary: MyMacsSummaryAvailability
        switch availability {
        case let .ready(lastUpdated, summaryAvailability):
            previousDate = lastUpdated
            summary = summaryAvailability
        case let .staleRetained(lastUpdated, _, _, summaryAvailability):
            previousDate = lastUpdated
            summary = summaryAvailability
        case .loading, .signedOut, .unavailable:
            return
        }

        let refreshedAt = max(requestedDate, previousDate.addingTimeInterval(1))
        snapshot.asOf = refreshedAt
        self.snapshot = snapshot
        availability = .ready(lastUpdated: refreshedAt, summary: summary)
    }

    private func apply(_ state: MyMacsFixtureState) {
        availability = state.availability
        snapshot = state.snapshot
    }
}
