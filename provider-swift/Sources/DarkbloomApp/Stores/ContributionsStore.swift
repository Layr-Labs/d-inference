import Foundation
import Observation

enum ContributionsFixture: String, CaseIterable, Sendable {
    case active
    case empty
    case payoutNotReady = "payout-not-ready"
    case unavailable
}

enum ContributionsAvailability: Equatable, Sendable {
    case available(lastUpdated: Date)
    case unavailable(message: String)
}

@MainActor
@Observable
final class ContributionsStore {
    private(set) var availability: ContributionsAvailability
    private(set) var snapshot: ContributionsSnapshot?
    /// Decorative seven-day series for UI evaluation only. This is intentionally
    /// separate from the coordinator-shaped snapshot.
    private(set) var pulsePreview: ContributionPulsePreview?
    var scope: ContributionScope
    private(set) var previewPayoutState: PreviewPayoutState = .idle
    private(set) var previewPayoutHistory: [PreviewPayoutReceipt] = []
    private(set) var payoutError: PayoutValidationError?

    private var previewPayoutSequence = 1

    init(
        fixture: ContributionsFixture = .active,
        initialScope: ContributionScope = .thisMac
    ) {
        let state = ContributionsFixtures.make(fixture)
        availability = state.availability
        snapshot = state.snapshot
        pulsePreview = state.pulsePreview
        scope = initialScope
    }

    var filteredLedger: [ContributionRecord] {
        guard let snapshot else { return [] }
        let records: [ContributionRecord]
        switch scope {
        case .thisMac:
            records = snapshot.records.filter {
                $0.providerKey == snapshot.currentProviderKey
            }
        case .allMacs:
            records = snapshot.records
        }
        return records.sorted {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp > $1.timestamp
        }
    }

    /// Token count derived only from the currently displayed, bounded ledger.
    /// This is not an account-lifetime metric.
    var shownRecordsTokenCount: UInt64 {
        filteredLedger.reduce(0) { total, record in
            Self.saturatingAdd(total, record.totalTokens)
        }
    }

    var isEmpty: Bool {
        guard let snapshot else { return false }
        return snapshot.lifetimeJobs == 0 && snapshot.records.isEmpty
    }

    func setScope(_ scope: ContributionScope) {
        self.scope = scope
    }

    func validatePayout(_ amount: MicroUSD) -> PayoutValidationError? {
        guard case .available = availability, let snapshot else {
            return .unavailable
        }
        if case .submitting = previewPayoutState {
            return .alreadySubmitting
        }
        guard snapshot.payoutReadiness == .ready else {
            return .setupRequired
        }
        guard amount > .zero else {
            return .nonPositive
        }
        guard amount >= snapshot.minimumPayout else {
            return .belowMinimum(minimum: snapshot.minimumPayout)
        }
        guard amount <= snapshot.withdrawableBalance else {
            return .exceedsWithdrawable(withdrawable: snapshot.withdrawableBalance)
        }
        return nil
    }

    @discardableResult
    func requestPreviewPayout(amount: MicroUSD) -> PreviewPayoutRequestResult {
        if let error = validatePayout(amount) {
            payoutError = error
            return .rejected(error)
        }

        let sequence = previewPayoutSequence
        previewPayoutSequence += 1
        let request = PreviewPayoutRequest(
            id: String(format: "preview-payout-%03d", sequence),
            requestedAt: ContributionsFixtures.previewPayoutTimestamp
                .addingTimeInterval(TimeInterval(sequence - 1) * 60),
            amount: amount
        )
        payoutError = nil
        previewPayoutState = .submitting(request)
        return .accepted(request)
    }

    /// Completes the deterministic preview request without changing coordinator-
    /// authoritative balances. The receipt stays separate from the earning ledger.
    @discardableResult
    func advancePreviewPayout() -> PreviewPayoutReceipt? {
        guard case .submitting(let request) = previewPayoutState else {
            return nil
        }

        let receipt = PreviewPayoutReceipt(
            id: request.id,
            requestedAt: request.requestedAt,
            completedAt: request.requestedAt
                .addingTimeInterval(ContributionsFixtures.previewPayoutCompletionDelay),
            amount: request.amount
        )
        previewPayoutHistory.insert(receipt, at: 0)
        previewPayoutState = .completed(receipt)
        return receipt
    }

    func cancelPreviewPayout() {
        guard case .submitting = previewPayoutState else { return }
        previewPayoutState = .idle
    }

    func acknowledgeCompletedPreviewPayout() {
        guard case .completed = previewPayoutState else { return }
        previewPayoutState = .idle
    }

    func dismissPayoutError() {
        payoutError = nil
    }

    /// Deterministic UI-only recovery until a real contributions service exists.
    func retryPreviewLoad() {
        guard case .unavailable = availability else { return }
        let state = ContributionsFixtures.make(.active)
        availability = state.availability
        snapshot = state.snapshot
        pulsePreview = state.pulsePreview
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
