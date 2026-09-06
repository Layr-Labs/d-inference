import Foundation
import Observation

enum ContributionsFixture: String, CaseIterable, Sendable {
    case active
    case empty
    case payoutNotReady = "payout-not-ready"
    case unavailable
}

enum ContributionsAvailability: Equatable, Sendable {
    /// Live store before its first fetch completes (fixture stores never use it).
    case loading
    case available(lastUpdated: Date)
    case unavailable(message: String)
}

@MainActor
@Observable
final class ContributionsStore {
    private(set) var availability: ContributionsAvailability
    private(set) var snapshot: ContributionsSnapshot?
    private(set) var accountLinkNeedsRefresh = false
    /// Decorative seven-day series for UI evaluation only. This is intentionally
    /// separate from the coordinator-shaped snapshot.
    private(set) var pulsePreview: ContributionPulsePreview?
    private(set) var scope: ContributionScope
    private(set) var previewPayoutState: PreviewPayoutState = .idle
    private(set) var previewPayoutHistory: [PreviewPayoutReceipt] = []
    private(set) var payoutError: PayoutValidationError?

    private var previewPayoutSequence = 1
    private var refreshRevision: UInt64 = 0
    private let live: LiveContext?

    struct LiveContext: Sendable {
        let cli: any ContributionsCLIRunning
        let now: @Sendable () -> Date
    }

    init(
        fixture: ContributionsFixture = .active,
        initialScope: ContributionScope = .thisMac
    ) {
        let state = ContributionsFixtures.make(fixture)
        availability = state.availability
        snapshot = state.snapshot
        pulsePreview = state.pulsePreview
        scope = initialScope
        live = nil
    }

    /// Live store: feeds from authenticated `darkbloom earnings --json`.
    /// Starts in `.loading`; the view's first appear (or retry) drives refresh.
    init(cli: any ContributionsCLIRunning, now: @escaping @Sendable () -> Date = Date.init) {
        availability = .loading
        snapshot = nil
        pulsePreview = nil
        scope = .thisMac
        live = LiveContext(cli: cli, now: now)
    }

    /// Live only: fetch the earnings endpoint and remap into coordinator-
    /// shaped snapshot state. Safe for fixture stores (no-op) so views can
    /// call it unconditionally.
    func refresh() async {
        guard let live else { return }
        refreshRevision &+= 1
        let revision = refreshRevision
        do {
            let payload = try await live.cli.fetchEarnings()
            guard revision == refreshRevision else { return }
            snapshot = ContributionsLiveMapping.snapshot(from: payload, asOf: live.now())
            accountLinkNeedsRefresh = false
            if !canIdentifyThisMac { scope = .allMacs }
            // The pulse series is a UI-preview-only artifact by contract
            // ("must never be presented as observed account data"): live mode
            // leaves it absent and the view shows the privacy note alone.
            pulsePreview = nil
            availability = .available(lastUpdated: live.now())
        } catch {
            guard revision == refreshRevision else { return }
            accountLinkNeedsRefresh = (error as? ContributionsCLIError) == .accountLinkNeedsRefresh
            availability = .unavailable(message: error.localizedDescription)
        }
    }

    var filteredLedger: [ContributionRecord] {
        guard let snapshot else { return [] }
        let records: [ContributionRecord]
        switch scope {
        case .thisMac:
            records = snapshot.records.filter {
                snapshot.currentProviderKeys.contains($0.providerKey)
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

    var isLive: Bool { live != nil }

    var canIdentifyThisMac: Bool {
        snapshot?.currentProviderKeys.isEmpty == false
    }

    func setScope(_ scope: ContributionScope) {
        guard scope != .thisMac || canIdentifyThisMac else { return }
        self.scope = scope
    }

    /// Invalidates all account-derived state at the moment the app account
    /// changes. Incrementing the revision also rejects an older account's
    /// response if it arrives after logout or a replacement sign-in.
    func accountSessionDidChange(isSignedIn: Bool) {
        guard live != nil else { return }
        refreshRevision &+= 1
        snapshot = nil
        accountLinkNeedsRefresh = false
        pulsePreview = nil
        scope = .thisMac
        previewPayoutState = .idle
        previewPayoutHistory = []
        payoutError = nil
        availability = isSignedIn
            ? .loading
            : .unavailable(message: "Sign in to view account contributions.")
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

    /// UI-troubleshooting recovery: fixtures restore their deterministic
    /// state; live stores refetch the earnings endpoint.
    func retryPreviewLoad() {
        guard case .unavailable = availability else { return }
        guard live == nil else {
            // Close the retry gate synchronously so rapid clicks cannot create
            // duplicate requests. The revision check in refresh also prevents
            // any older in-flight response from replacing the retry result.
            availability = .loading
            Task { await refresh() }
            return
        }
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
