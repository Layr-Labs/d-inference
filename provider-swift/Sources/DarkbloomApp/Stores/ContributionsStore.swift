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
    /// Decorative seven-day series for UI evaluation only. This is intentionally
    /// separate from the coordinator-shaped snapshot. Live stores replace it
    /// with a series derived from the fetched payout rows.
    private(set) var pulsePreview: ContributionPulsePreview?
    var scope: ContributionScope
    private(set) var previewPayoutState: PreviewPayoutState = .idle
    private(set) var previewPayoutHistory: [PreviewPayoutReceipt] = []
    private(set) var payoutError: PayoutValidationError?

    private var previewPayoutSequence = 1
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

    /// Live store: feeds from `darkbloom earnings --json` (the coordinator's
    /// no-auth provider earnings endpoint). Starts in `.loading`; the view's
    /// first appear (or the retry action) drives `refresh()`.
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
        do {
            let payload = try await live.cli.fetchEarnings()
            snapshot = ContributionsLiveMapping.snapshot(from: payload, asOf: live.now())
            // The pulse series is a UI-preview-only artifact by contract
            // ("must never be presented as observed account data"): live mode
            // leaves it absent and the view shows the privacy note alone.
            pulsePreview = nil
            availability = .available(lastUpdated: live.now())
        } catch {
            availability = .unavailable(message: error.localizedDescription)
        }
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

    /// UI-troubleshooting recovery: fixtures restore their deterministic
    /// state; live stores refetch the earnings endpoint.
    func retryPreviewLoad() {
        guard case .unavailable = availability else { return }
        guard live == nil else {
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

// MARK: - Live mapping (earnings payload -> snapshot)

/// Maps the coordinator's wallet-keyed earnings payload onto the app's
/// coordinator-shaped models. Exact integer micro-USD end to end; fields the
/// endpoint does not report are derived conservatively and documented here:
///
/// - `withdrawableBalance` mirrors `balance_micro_usd`: the wallet endpoint
///   does not split withdrawable vs. pending (that split exists only on the
///   authenticated account endpoint), so the invariant
///   `withdrawable <= available` holds trivially and the UI's payout
///   validation floors against the full balance.
/// - `minimumPayout` is an app-side display floor ($1), not a coordinator
///   rule — the endpoint has no minimum concept.
/// - Records come from `payouts` only; `ledger` rows are account-audit
///   metadata, not per-job earnings.
enum ContributionsLiveMapping {
    /// Display-only payout floor for the live snapshot. Matches the fixture
    /// value so preview and live surfaces describe payouts identically.
    static let liveMinimumPayout = MicroUSD(1_000_000)

    static func snapshot(from payload: ContributionsEarningsPayload, asOf: Date) -> ContributionsSnapshot {
        // The wallet this payload was fetched for (echoed by the CLI) keys
        // every record: the endpoint already filtered payouts to that
        // address. A bare coordinator payload (tests only) leaves it empty —
        // the snapshot requires a non-empty key, so substitute a marker.
        let wallet = (payload.wallet?.isEmpty == false) ? payload.wallet! : "unknown-wallet"
        let records = payload.payouts.map { record(from: $0, wallet: wallet, asOf: asOf) }
        return ContributionsSnapshot(
            asOf: asOf,
            currentProviderKey: wallet,
            availableBalance: nonNegative(payload.balanceMicroUSD),
            withdrawableBalance: nonNegative(payload.balanceMicroUSD),
            earnedLifetime: nonNegative(payload.totalEarnedMicroUSD),
            lifetimeJobs: Int64(max(0, payload.totalJobs)),
            minimumPayout: liveMinimumPayout,
            payoutReadiness: .ready,
            records: records
        )
    }

    private static func record(
        from payout: ContributionsEarningsPayload.Payout,
        wallet: String,
        asOf: Date
    ) -> ContributionRecord {
        // Stable unique ids prefer the store row id; ledger-reconstructed
        // rows (id 0) fall back to the job reference.
        let id: String
        if payout.id != 0 {
            id = "payout-\(payout.id)"
        } else if let jobID = payout.jobID, !jobID.isEmpty {
            id = "job-\(jobID)"
        } else {
            id = "payout-\(payout.timestamp.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown")"
        }
        let modelID = (payout.model?.isEmpty == false) ? payout.model! : "unknown"
        return ContributionRecord(
            id: id,
            timestamp: min(payout.timestamp ?? asOf, asOf),
            providerKey: wallet,
            providerID: (payout.jobID?.isEmpty == false) ? payout.jobID! : id,
            providerName: "This Mac",
            modelID: modelID,
            modelName: modelID,
            inputTokens: 0,
            outputTokens: 0,
            amount: nonNegative(payout.amountMicroUSD)
        )
    }

    /// Defensive clamp: the coordinator only ever writes non-negative payout
    /// amounts, but `MicroUSD` preconditions on it — a corrupt row must not
    /// crash the app.
    private static func nonNegative(_ value: Int64) -> MicroUSD {
        MicroUSD(validating: value) ?? .zero
    }
}
