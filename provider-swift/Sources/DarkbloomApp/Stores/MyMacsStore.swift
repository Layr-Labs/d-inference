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

/// Store mode: deterministic fixture previews or the live coordinator-backed
/// account session. Fixture mode and `init(fixture:)` are untouched by the
/// live wiring so previews and their pinned tests stay deterministic.
enum MyMacsStoreMode: Equatable, Sendable {
    case fixture
    case live
}

@MainActor
@Observable
final class MyMacsStore {
    /// User-facing copy shared with the live-mode transitions. Kept identical
    /// to the fixture strings so a live failure looks exactly like its
    /// preview pin.
    private enum LiveCopy {
        static let unavailable = "Darkbloom could not load the Macs linked to this account."
        static let refreshFailed = "Refresh failed. Showing the last account snapshot."
        static let summaryUnavailable =
            "Machine status is current, but the account summary is unavailable."
    }

    private(set) var availability: MyMacsAvailability
    private(set) var snapshot: MyMacsSnapshot?

    /// Live-mode-only surface: sign-in handoff bookkeeping.
    private(set) var isSigningIn = false
    private(set) var signInErrorMessage: String?

    @ObservationIgnored
    let mode: MyMacsStoreMode
    @ObservationIgnored
    private let session: (any AccountSessionManaging)?
    @ObservationIgnored
    private let fleet: (any FleetServicing)?
    @ObservationIgnored
    private var didStart = false
    @ObservationIgnored
    private var liveTask: Task<Void, Never>?
    @ObservationIgnored
    private var liveRevision: UInt64 = 0

    init(fixture: MyMacsFixture = .ready) {
        let state = MyMacsFixtures.make(fixture)
        availability = state.availability
        snapshot = state.snapshot
        mode = .fixture
        session = nil
        fleet = nil
    }

    /// Live store: reads the persisted account session (Privy token in the
    /// keychain) and the coordinator's account-scoped fleet endpoints.
    /// Network starts only via `start()` / user actions — never from init.
    init(session: any AccountSessionManaging, fleet: any FleetServicing) {
        availability = .loading
        snapshot = nil
        mode = .live
        self.session = session
        self.fleet = fleet
    }

    deinit {
        liveTask?.cancel()
    }

    var macs: [MyMac] {
        snapshot?.macs ?? []
    }

    var isEmpty: Bool {
        guard snapshot != nil else { return false }
        return macs.isEmpty
    }

    var canRefresh: Bool {
        switch availability {
        case .ready, .staleRetained:
            snapshot != nil
        case .loading, .signedOut, .unavailable:
            false
        }
    }

    // Kept for the fixture-transition tests pinned to the preview name.
    var canRefreshPreview: Bool { canRefresh }

    func mac(id: String) -> MyMac? {
        macs.first { $0.id == id }
    }

    // MARK: - Mode-dispatched actions (consumed by MyMacsView)

    /// Kicks the live session check + first fetch. Idempotent. Fixture mode
    /// ignores this so preview captures stay untouched.
    func start() {
        guard mode == .live, !didStart else { return }
        didStart = true
        guard let session, session.isSignedIn else {
            invalidateLiveWork()
            availability = .signedOut
            return
        }
        availability = .loading
        scheduleRefreshLive()
    }

    func signIn() {
        signInErrorMessage = nil
        switch mode {
        case .fixture:
            signInPreview()
        case .live:
            guard !isSigningIn else { return }
            liveTask?.cancel()
            let revision = nextLiveRevision()
            isSigningIn = true
            liveTask = Task { [weak self] in
                await self?.signInLive(revision: revision)
            }
        }
    }

    func refresh() {
        switch mode {
        case .fixture:
            refreshPreview()
        case .live:
            scheduleRefreshLive()
        }
    }

    func retry() {
        switch mode {
        case .fixture:
            retryPreviewLoad()
        case .live:
            scheduleRefreshLive()
        }
    }

    func signOut() {
        guard mode == .live else { return }
        // A Privy token in an ephemeral browser leaves no shared browser
        // session, so signing out is purely local — coordinator tokens
        // self-expire server-side.
        invalidateLiveWork()
        session?.signOut()
        didStart = false
        snapshot = nil
        isSigningIn = false
        signInErrorMessage = nil
        availability = .signedOut
    }

    /// Removes a retained machine. Fixture mode applies the local bookkeeping
    /// synchronously; live mode DELETEs `removalToken` coordinates-side first
    /// and applies the same bookkeeping only after the coordinator confirms.
    @discardableResult
    func removeMac(id: String) async -> Bool {
        switch mode {
        case .fixture:
            return removePreviewMac(id: id)
        case .live:
            return await removeMacLive(id: id)
        }
    }

    // MARK: - Live transitions (mirrors of the fixture state machine)

    func signInLive() async {
        liveTask?.cancel()
        liveTask = nil
        let revision = nextLiveRevision()
        isSigningIn = true
        await signInLive(revision: revision)
    }

    private func signInLive(revision: UInt64) async {
        defer {
            if revision == liveRevision {
                isSigningIn = false
            }
        }
        guard let session else { return }
        do {
            let bearerToken = try await session.signIn()
            // signOut() may have raced the minutes-long auth browser; that
            // transition owns the state — never resurrect inventory after it.
            guard canPublish(revision: revision, bearerToken: bearerToken) else {
                // AccountSessionManager persists in the browser callback. If a
                // sign-out won the race and no replacement sign-in is active,
                // clear that stale callback token as well as suppressing UI.
                if !isSigningIn,
                   case .signedOut = availability,
                   session.accessToken() == bearerToken {
                    session.signOut()
                }
                return
            }
            signInErrorMessage = nil
            await refreshLive(
                at: .now,
                revision: revision,
                bearerToken: bearerToken
            )
        } catch AccountSessionError.cancelled {
            // User dismissed the auth browser: stay signed out, silently.
            // Restore .signedOut if sign-in started from a pre-session state
            // (e.g. start() raced the CTA) — never an error, never a hang in
            // .loading.
            guard canPublish(revision: revision) else { return }
            if snapshot == nil, session.accessToken() == nil {
                availability = .signedOut
            }
        } catch {
            guard canPublish(revision: revision) else { return }
            signInErrorMessage = error.localizedDescription
            availability = .signedOut
        }
    }

    func refreshLive(at date: Date = .now) async {
        liveTask?.cancel()
        liveTask = nil
        let revision = nextLiveRevision()
        guard let bearerToken = session?.accessToken() else {
            // No usable session: the coordinator cannot be queried at all.
            snapshot = nil
            availability = .signedOut
            return
        }
        await refreshLive(at: date, revision: revision, bearerToken: bearerToken)
    }

    private func refreshLive(
        at date: Date,
        revision: UInt64,
        bearerToken: String
    ) async {
        guard let fleet, canPublish(revision: revision, bearerToken: bearerToken) else {
            return
        }
        do {
            let providers = try await fleet.providers(bearerToken: bearerToken)
            guard canPublish(revision: revision, bearerToken: bearerToken) else {
                return
            }
            // Summary is best-effort: the providers payload alone is
            // sufficient to render inventory (see MyMacsSnapshot).
            let summary = try? await fleet.summary(bearerToken: bearerToken)
            guard canPublish(revision: revision, bearerToken: bearerToken) else {
                return
            }
            let updated = try MyMacsSnapshot(providers: providers, summary: summary, asOf: date)
            guard canPublish(revision: revision, bearerToken: bearerToken) else {
                return
            }
            snapshot = updated
            availability = .ready(
                lastUpdated: date,
                summary: updated.accountSummary == nil
                    ? .unavailable(message: LiveCopy.summaryUnavailable)
                    : .available
            )
        } catch is CancellationError {
            // signOut() raced the fetch; it already owns the state.
        } catch FleetClientError.sessionExpired {
            // Coordinator rejected the Privy token: drop it so the user
            // re-authenticates instead of streaming repeated 401s.
            expireSessionIfCurrent(revision: revision, bearerToken: bearerToken)
        } catch {
            guard canPublish(revision: revision, bearerToken: bearerToken) else {
                return
            }
            if let retained = snapshot {
                availability = .staleRetained(
                    lastUpdated: retained.asOf,
                    failedAt: date,
                    message: LiveCopy.refreshFailed,
                    summary: currentSummaryAvailability
                )
            } else {
                availability = .unavailable(message: LiveCopy.unavailable)
            }
        }
    }

    private func scheduleRefreshLive() {
        liveTask?.cancel()
        let revision = nextLiveRevision()
        guard let bearerToken = session?.accessToken() else {
            liveTask = nil
            snapshot = nil
            availability = .signedOut
            return
        }
        liveTask = Task { [weak self] in
            await self?.refreshLive(
                at: .now,
                revision: revision,
                bearerToken: bearerToken
            )
        }
    }

    @discardableResult
    private func nextLiveRevision() -> UInt64 {
        liveRevision &+= 1
        return liveRevision
    }

    private func invalidateLiveWork() {
        _ = nextLiveRevision()
        liveTask?.cancel()
        liveTask = nil
    }

    private func canPublish(revision: UInt64, bearerToken: String? = nil) -> Bool {
        guard !Task.isCancelled, revision == liveRevision else { return false }
        guard let bearerToken else { return true }
        return session?.accessToken() == bearerToken
    }

    private func expireSessionIfCurrent(revision: UInt64, bearerToken: String) {
        guard canPublish(revision: revision, bearerToken: bearerToken) else {
            return
        }
        _ = nextLiveRevision()
        session?.signOut()
        snapshot = nil
        signInErrorMessage = nil
        availability = .signedOut
    }

    private func removeMacLive(id: String, at date: Date = .now) async -> Bool {
        guard let session, let fleet,
              let mac = mac(id: id),
              mac.canRemove,
              let removalToken = mac.removalToken
        else {
            return false
        }
        liveTask?.cancel()
        liveTask = nil
        let revision = nextLiveRevision()
        guard let bearerToken = session.accessToken() else {
            snapshot = nil
            availability = .signedOut
            return false
        }

        do {
            try await fleet.deleteProvider(removalToken: removalToken, bearerToken: bearerToken)
        } catch FleetClientError.sessionExpired {
            expireSessionIfCurrent(revision: revision, bearerToken: bearerToken)
            return false
        } catch {
            guard canPublish(revision: revision, bearerToken: bearerToken) else {
                return false
            }
            // 403 (not owned), 404 (already gone), 409 (still online),
            // transport: retain the inventory and surface the failure without
            // collapsing the page into the unavailable state.
            guard let retained = snapshot else {
                availability = .unavailable(message: LiveCopy.unavailable)
                return false
            }
            availability = .staleRetained(
                lastUpdated: retained.asOf,
                failedAt: date,
                message: "Could not remove that Mac. \(error.localizedDescription)",
                summary: currentSummaryAvailability
            )
            return false
        }

        // Coordinator confirmed: apply the identical local bookkeeping the
        // preview path uses (counts reconcile, activity totals retained).
        guard canPublish(revision: revision, bearerToken: bearerToken) else {
            return false
        }
        return removePreviewMac(id: id, at: date)
    }

    private var currentSummaryAvailability: MyMacsSummaryAvailability {
        switch availability {
        case let .ready(_, summary), let .staleRetained(_, _, _, summary):
            summary
        case .loading, .signedOut, .unavailable:
            .unavailable(message: LiveCopy.summaryUnavailable)
        }
    }

    // MARK: - Preview transitions (fixture mode; unchanged behavior)

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

    /// Removes only a coordinator-removable retained record and reconciles
    /// the local inventory counts. Earnings and job history remain
    /// account-scoped, so this updates inventory counts but intentionally
    /// leaves activity totals untouched. Used by fixture previews AND by the
    /// live path after the coordinator confirms a DELETE.
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
