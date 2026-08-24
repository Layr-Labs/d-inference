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
    /// separate from the coordinator-shaped snapshot.
    private(set) var pulsePreview: ContributionPulsePreview?
    var scope: ContributionScope
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
            // The pulse series is a UI-preview-only artifact by contract
            // ("must never be presented as observed account data"): live mode
            // leaves it absent and the view shows the privacy note alone.
            pulsePreview = nil
            availability = .available(lastUpdated: live.now())
        } catch {
            guard revision == refreshRevision else { return }
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

// MARK: - Live mapping (earnings payload -> snapshot)

/// Maps authenticated account earnings onto privacy-safe app records. The
/// coordinator includes provider-key/session-to-machine mappings so every
/// ephemeral key from this physical Mac remains in the "This Mac" scope.
enum ContributionsLiveMapping {
    static let liveMinimumPayout = MicroUSD(1_000_000)

    static func snapshot(from payload: ContributionsEarningsPayload, asOf: Date) -> ContributionsSnapshot {
        let providersByKey = Dictionary(
            payload.providers.filter { !$0.providerKey.isEmpty }.map { ($0.providerKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let providersByID = Dictionary(
            payload.providers.filter { !$0.providerID.isEmpty }.map { ($0.providerID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var currentProviderKeys = Set<String>()
        if let currentKey = payload.currentProviderKey, !currentKey.isEmpty {
            currentProviderKeys.insert(currentKey)
        }
        if let currentMachineID = payload.currentMachineID, !currentMachineID.isEmpty {
            currentProviderKeys.formUnion(payload.providers.lazy
                .filter { $0.machineID == currentMachineID }
                .map(\.providerKey)
                .filter { !$0.isEmpty })
        }
        let records = payload.earnings.enumerated().map { index, earning in
            record(
                from: earning,
                fallbackIndex: index,
                providersByKey: providersByKey,
                providersByID: providersByID,
                currentMachineID: payload.currentMachineID,
                asOf: asOf
            )
        }
        return ContributionsSnapshot(
            asOf: asOf,
            currentProviderKeys: currentProviderKeys,
            availableBalance: nonNegative(payload.availableBalanceMicroUSD),
            withdrawableBalance: min(
                nonNegative(payload.withdrawableBalanceMicroUSD),
                nonNegative(payload.availableBalanceMicroUSD)
            ),
            earnedLifetime: nonNegative(payload.totalMicroUSD),
            lifetimeJobs: max(0, payload.count),
            minimumPayout: liveMinimumPayout,
            payoutReadiness: .ready,
            records: records
        )
    }

    private static func record(
        from earning: ContributionsEarningsPayload.Earning,
        fallbackIndex: Int,
        providersByKey: [String: ContributionsEarningsPayload.ProviderIdentity],
        providersByID: [String: ContributionsEarningsPayload.ProviderIdentity],
        currentMachineID: String?,
        asOf: Date
    ) -> ContributionRecord {
        let id: String
        if earning.id != 0 {
            id = "earning-\(earning.id)"
        } else if !earning.jobID.isEmpty {
            id = "job-\(earning.jobID)"
        } else {
            id = "earning-fallback-\(fallbackIndex)"
        }
        let providerKey = earning.providerKey.isEmpty
            ? (earning.providerID.isEmpty ? "unknown-provider" : earning.providerID)
            : earning.providerKey
        let providerID = earning.providerID.isEmpty ? providerKey : earning.providerID
        let identity = providersByKey[earning.providerKey] ?? providersByID[earning.providerID]
        let modelID = earning.model.isEmpty ? "unknown" : earning.model
        return ContributionRecord(
            id: id,
            timestamp: min(earning.createdAt ?? asOf, asOf),
            providerKey: providerKey,
            providerID: providerID,
            providerName: providerName(
                identity: identity,
                currentMachineID: currentMachineID
            ),
            modelID: modelID,
            modelName: modelID == "base_reward" ? "Base reward" : modelID,
            inputTokens: nonNegativeTokens(earning.promptTokens),
            outputTokens: nonNegativeTokens(earning.completionTokens),
            amount: nonNegative(earning.amountMicroUSD)
        )
    }

    private static func providerName(
        identity: ContributionsEarningsPayload.ProviderIdentity?,
        currentMachineID: String?
    ) -> String {
        guard let machineID = identity?.machineID, !machineID.isEmpty else {
            return "Provider"
        }
        if machineID == currentMachineID {
            return "This Mac"
        }
        return "Mac ••••\(machineID.suffix(4).uppercased())"
    }

    private static func nonNegative(_ value: Int64) -> MicroUSD {
        MicroUSD(validating: value) ?? .zero
    }

    private static func nonNegativeTokens(_ value: Int) -> UInt64 {
        value > 0 ? UInt64(value) : 0
    }
}
