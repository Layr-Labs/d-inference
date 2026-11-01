import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

/// `status`/`doctor` must say why a connected provider with a warm model gets
/// no coordinator work. Field reports ("no traffic until restart", "am I
/// banned?", "Trust: awaiting coordinator status") all came from connections
/// the coordinator was not authorizing while the Mac looked healthy.
@Suite struct ServingReadinessTests {
    private let now: Double = 1_000_000

    private func state(
        connected: Bool? = true, since: Double = 1_000_000 - 1_200,
        trust: DaemonState.Trust? = nil, appAttest: AppAttestLocalStatus? = nil
    ) -> DaemonState {
        var state = DaemonState(pid: 1, version: "test", writtenAt: now, startedAt: now - 3_600,
                                trust: trust, warmModels: ["glm"], advertisedModels: ["glm"])
        if let connected {
            state.coordinatorConnection = .init(connected: connected, since: since, connections: 1)
        }
        state.appAttest = appAttest
        return state
    }

    private func trust(path: String, reason: String, expiresAt: Double? = nil,
                       level: String = "self_signed", status: String = "online",
                       receivedAt: Double? = nil) -> DaemonState.Trust {
        DaemonState.Trust(
            trustLevel: level, status: status, reason: "Provider authorization updated",
            receivedAt: receivedAt ?? now - 30,
            authorization: ProviderAuthorizationStatus(
                appAttestAvailable: true, path: path, expiresAt: expiresAt, reason: reason,
                sessionID: "session", machineID: path == "none" ? "" : "machine"))
    }

    private func blocked(_ verdict: ServingReadiness.Verdict?) -> DiagnosticAdvice? {
        if case .blocked(let advice)? = verdict { return advice }
        return nil
    }

    @Test func olderDaemonWithoutConnectionReportHasNoVerdict() {
        #expect(ServingReadiness.verdict(state(connected: nil), now: now) == nil)
    }

    @Test func authorizedPathsAreEligible() {
        let appAttest = ServingReadiness.verdict(
            state(trust: trust(path: "app_attest", reason: "app_attest_verified", expiresAt: now + 600)), now: now)
        guard case .authorized(let detail)? = appAttest else {
            Issue.record("App Attest lease not reported as eligible: \(String(describing: appAttest))")
            return
        }
        #expect(detail.contains("App Attest authorized"))
        let legacy = ServingReadiness.verdict(
            state(trust: trust(path: "legacy", reason: "legacy_verification_active")), now: now)
        #expect(legacy == .authorized("legacy (MDM) verification active"))
        // A coordinator without App Attest serving sends no authorization object.
        let hardware = ServingReadiness.verdict(state(trust: DaemonState.Trust(
            trustLevel: "hardware", status: "online", reason: "MDM verification passed", receivedAt: now)), now: now)
        #expect(hardware == .authorized("hardware-trusted (legacy verification)"))
        // Below hardware trust such a coordinator's own trust floor decides.
        #expect(ServingReadiness.verdict(state(trust: DaemonState.Trust(
            trustLevel: "self_signed", status: "online", reason: "SE attestation verified", receivedAt: now)), now: now) == nil)
    }

    /// An add-on hold keeps the connection but leaves routing on purpose, and
    /// `status` prints the hold on its own line. Its authorization is not why
    /// no work arrives, so there is no verdict; a disconnect still is one.
    @Test func aConnectionAnAddonHoldsHasNoVerdict() throws {
        let holds = AddonHoldSnapshot(holds: [AddonHoldView(
            holdId: "hold", addon: "io.darkbloom.sandbox", state: "held", sinceMs: 0,
            leaseExpiresAtMs: 60_000, vmBytes: 8 << 30)])
        var authorized = state(trust: trust(path: "app_attest", reason: "app_attest_verified", expiresAt: now + 600))
        authorized.addonHold = holds
        #expect(ServingReadiness.verdict(authorized, now: now) == nil)
        var expired = state(trust: trust(path: "app_attest", reason: "app_attest_verified", expiresAt: now - 60))
        expired.addonHold = holds
        #expect(ServingReadiness.verdict(expired, now: now) == nil)
        var unconfirmed = state(since: now - 600)
        unconfirmed.addonHold = holds
        #expect(ServingReadiness.verdict(unconfirmed, now: now) == nil)

        var disconnected = state(connected: false, since: now - 120)
        disconnected.addonHold = holds
        #expect(blocked(ServingReadiness.verdict(disconnected, now: now))?.message
            .hasPrefix("not connected to the coordinator") == true)
        // A provider serving the add-on socket reports an empty snapshot when nothing holds it.
        var free = state(trust: trust(path: "legacy", reason: "legacy_verification_active"))
        free.addonHold = AddonHoldSnapshot(holds: [])
        #expect(ServingReadiness.verdict(free, now: now) == .authorized("legacy (MDM) verification active"))
    }

    @Test func disconnectedIsNotReceiving() throws {
        let advice = try #require(blocked(ServingReadiness.verdict(state(connected: false, since: now - 120), now: now)))
        #expect(advice.message.hasPrefix("not connected to the coordinator (disconnected 2m ago); "))
        // A reconnect loop shows as a rising registration count.
        var looping = state(connected: false, since: now - 5)
        looping.coordinatorConnection?.connections = 57
        let loop = try #require(blocked(ServingReadiness.verdict(looping, now: now)))
        #expect(loop.message.contains("(disconnected 5s ago; registration 57 since the provider started)"))
    }

    /// Mark's line: connected, no coordinator status. Brief after connecting
    /// that is normal; minutes later the coordinator never confirmed it.
    @Test func missingCoordinatorStatusIsPendingThenBlocked() throws {
        let early = ServingReadiness.verdict(state(since: now - 20), now: now)
        guard case .pending? = early else {
            Issue.record("expected pending right after connecting, got \(String(describing: early))")
            return
        }
        let advice = try #require(blocked(ServingReadiness.verdict(state(since: now - 600), now: now)))
        #expect(advice.message.contains("the coordinator has not confirmed this connection"))
        #expect(advice.fix?.contains("restart") == true)
    }

    @Test func expiredLeaseIsNotReceiving() throws {
        let advice = try #require(blocked(ServingReadiness.verdict(
            state(trust: trust(path: "app_attest", reason: "app_attest_verified", expiresAt: now - 60)), now: now)))
        #expect(advice.message.contains("App Attest authorization expired at"))
        // The lease names its own expiry, so an old status still proves it lapsed.
        #expect(blocked(ServingReadiness.verdict(state(since: now - 10_000, trust: trust(
            path: "app_attest", reason: "app_attest_verified", expiresAt: now - 3_600, receivedAt: now - 7_200)),
            now: now)) != nil)
    }

    /// The coordinator computes the registration status before it records
    /// the first verified challenge that legacy verification needs, so a
    /// refusal right after connecting is not a verdict yet.
    @Test func aRefusalRightAfterConnectingIsPending() {
        let verdict = ServingReadiness.verdict(state(since: now - 20, trust: trust(
            path: "none", reason: "app_attest_qualification_required", receivedAt: now - 19)), now: now)
        #expect(verdict == .pending("connected 20s ago; not authorized so far: app_attest_qualification_required"))
    }

    /// A legacy (MDM-cohort) Mac on the current coordinator: one refusal at
    /// registration, then no status when legacy verification authorizes the
    /// connection. Once that refusal is older than `refusalMaxAge` the verdict
    /// is unconfirmed, labelled as the last one, with no fix and no macOS 27.
    @Test func aRefusalTheCoordinatorStoppedRepeatingIsUnconfirmed() throws {
        let osTooOld = AppAttestLocalStatus(observedAt: now, launchSession: .unknown, availabilityReason: .osBelow27)
        func verdict(receivedAt: Double) -> ServingReadiness.Verdict? {
            ServingReadiness.verdict(state(trust: trust(
                path: "none", reason: "app_attest_qualification_required", receivedAt: receivedAt),
                appAttest: osTooOld), now: now, macOSMajorVersion: 26)
        }
        // A refusal the coordinator keeps repeating is current.
        let current = try #require(blocked(verdict(receivedAt: now - ServingReadiness.refusalMaxAge)))
        #expect(current.fix?.contains("upgrade to macOS 27") == true)

        let lastAtRegistration = verdict(receivedAt: now - 1_199)
        #expect(lastAtRegistration == .unconfirmed("no current coordinator verdict; the last one, 19m ago, "
            + "did not authorize this connection: app_attest_qualification_required"))
        guard case .unconfirmed(let detail)? = verdict(receivedAt: now - ServingReadiness.refusalMaxAge - 1) else {
            Issue.record("a refusal older than refusalMaxAge still blocks")
            return
        }
        #expect(!detail.contains("macOS 27"))
        #expect(ServingReadiness.refusalMaxAge < ServingReadiness.statusGraceSeconds)
    }

    /// A request the coordinator routed after its latest status is newer
    /// evidence than a refusal or a missing status, but not than an explicit
    /// `untrusted` status or an expired lease.
    @Test func aRequestAfterTheLatestStatusIsEligible() {
        func verdict(_ trust: DaemonState.Trust?, requestAt: Double) -> ServingReadiness.Verdict? {
            var routed = state(trust: trust)
            routed.coordinatorConnection?.lastRequestAt = requestAt
            return ServingReadiness.verdict(routed, now: now)
        }
        let refusal = trust(path: "none", reason: "app_attest_keychain_error", receivedAt: now - 30)
        #expect(verdict(refusal, requestAt: now - 10) == .authorized("received a coordinator request 10s ago"))
        #expect(blocked(verdict(refusal, requestAt: now - 31)) != nil)
        #expect(verdict(nil, requestAt: now - 300) == .authorized("received a coordinator request 5m ago"))
        let atRegistration = trust(path: "none", reason: "app_attest_qualification_required", receivedAt: now - 1_199)
        #expect(verdict(atRegistration, requestAt: now - 600) == .authorized("received a coordinator request 10m ago"))

        let untrusted = DaemonState.Trust(
            trustLevel: "self_signed", status: "untrusted", reason: "SIP disabled", receivedAt: now - 30)
        #expect(blocked(verdict(untrusted, requestAt: now - 10)) != nil)
        let lapsed = trust(path: "app_attest", reason: "app_attest_verified", expiresAt: now - 60, receivedAt: now - 120)
        #expect(blocked(verdict(lapsed, requestAt: now - 10)) != nil)
    }

    @Test func coordinatorReasonsMapToOperatorCauses() throws {
        func advice(_ reason: String, macOS: Int = 27) throws -> DiagnosticAdvice {
            try #require(blocked(ServingReadiness.verdict(
                state(trust: trust(path: "none", reason: reason)), now: now, macOSMajorVersion: macOS)))
        }
        #expect(try advice("app_attest_keychain_error").fix?.contains("unlock the login keychain") == true)
        #expect(try advice("app_attest_identity_required").fix?.contains("login") == true)
        #expect(try advice("app_attest_busy").message.contains("did not return in time"))
        #expect(try advice("app_attest_unsupported", macOS: 26).message.contains("App Attest needs macOS 27"))
        #expect(try advice("app_attest_unsupported", macOS: 27).message.contains("logged-in GUI session"))
        #expect(try advice("app_attest_provider_upgrade_required").fix?.contains("update") == true)
        #expect(try advice("app_attest_qualification_required").message.contains("has not qualified this connection"))
        #expect(try advice("app_attest_signature").message.contains("(signature)"))
        #expect(try advice("some_new_reason").message.hasSuffix("some_new_reason"))
    }

    /// The local App Attest observation is more specific than a generic
    /// coordinator reason: a stalled Apple call answers busy until restart.
    @Test func localAppAttestStallOverridesGenericReason() throws {
        let stalled = AppAttestLocalStatus(observedAt: now, launchSession: .unknown, operationStalledSeconds: 1_800)
        let advice = try #require(blocked(ServingReadiness.verdict(
            state(trust: trust(path: "none", reason: "app_attest_qualification_required"), appAttest: stalled), now: now)))
        #expect(advice.message.contains("has not returned for 30m"))
        let osTooOld = AppAttestLocalStatus(observedAt: now, launchSession: .unknown, availabilityReason: .osBelow27)
        let old = try #require(blocked(ServingReadiness.verdict(
            state(trust: trust(path: "none", reason: "app_attest_unsupported"), appAttest: osTooOld), now: now,
            macOSMajorVersion: 26)))
        #expect(old.fix?.contains("upgrade to macOS 27") == true)
        // `update` leaves a current version in place, so the fix reinstalls.
        let unsigned = AppAttestLocalStatus(observedAt: now, launchSession: .unknown, availabilityReason: .notAppBundle)
        let reinstall = try #require(blocked(ServingReadiness.verdict(
            state(trust: trust(path: "none", reason: "app_attest_unsupported"), appAttest: unsigned), now: now)))
        #expect(reinstall.message.hasSuffix("cannot use App Attest (not_app_bundle)"))
        #expect(reinstall.fix?.contains("/install.sh | bash`, then `") == true)
    }

    @Test func untrustedIsNotReceiving() throws {
        let advice = try #require(blocked(ServingReadiness.verdict(state(trust: DaemonState.Trust(
            trustLevel: "self_signed", status: "untrusted", reason: "SIP disabled", receivedAt: now)), now: now)))
        #expect(advice.message.contains("System Integrity Protection"))
        // The coordinator sends a status when it trusts the connection again.
        #expect(blocked(ServingReadiness.verdict(state(since: now - 10_000, trust: DaemonState.Trust(
            trustLevel: "self_signed", status: "untrusted", reason: "SIP disabled", receivedAt: now - 7_200)),
            now: now)) != nil)
    }

    @Test func connectionStateRoundTripsThroughTheStateFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var written = state(trust: trust(path: "none", reason: "app_attest_keychain_error"))
        written.coordinatorConnection?.lastRequestAt = now - 5
        DaemonStateFile.write(written, to: url)
        let read = try #require(DaemonStateFile.read(from: url))
        #expect(read.coordinatorConnection == written.coordinatorConnection)
        #expect(read.trust?.authorization?.reason == "app_attest_keychain_error")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"last_request_at\""))
    }
}

/// When the provider re-registers a connection the coordinator keeps refusing.
@Suite struct UnauthorizedConnectionRecoveryTests {
    private typealias Policy = UnauthorizedConnectionRecovery

    @Test func reconnectsOnlyAfterTheThresholdWhileIdleWithBackoff() {
        let now = 100_000.0
        func due(since: Double?, last: Double? = nil, attempts: Int = 0, busy: Bool = false, jitter: Double = 0) -> Bool {
            Policy.shouldReconnect(unauthorizedSince: since, lastReconnectAt: last, attempts: attempts,
                                   busy: busy, jitter: jitter, now: now)
        }
        #expect(!due(since: nil))
        #expect(!due(since: now - Policy.unauthorizedThreshold + 1))
        #expect(due(since: now - Policy.unauthorizedThreshold))
        #expect(!due(since: now - Policy.unauthorizedThreshold, busy: true))
        // The per-process jitter only delays the first attempt.
        #expect(!due(since: now - Policy.unauthorizedThreshold, jitter: 60))
        #expect(due(since: now - Policy.unauthorizedThreshold - 60, jitter: 60))
        // Later attempts wait 30 min, then 1 h, 2 h, capped at 4 h.
        #expect(!due(since: now - 7_200, last: now - Policy.firstRetryInterval + 1, attempts: 1))
        #expect(due(since: now - 7_200, last: now - Policy.firstRetryInterval, attempts: 1))
        #expect(!due(since: now - 7_200, last: now - 3_599, attempts: 2))
        #expect(due(since: now - 7_200, last: now - 3_600, attempts: 2))
        #expect(Policy.retryInterval(afterAttempts: 3) == 7_200)
        #expect(Policy.retryInterval(afterAttempts: 10) == Policy.maximumRetryInterval)
    }

    /// Re-registration counts only the blocked `ServingReadiness` verdict
    /// that `status` and `doctor` show.
    @Test func judgesOnlyCoordinatorVerdictsItCanRead() {
        let now = 100_000.0
        func trust(_ path: String?, expiresAt: Double? = nil, status: String = "online",
                   receivedAt: Double = 100_000) -> DaemonState.Trust {
            DaemonState.Trust(trustLevel: "self_signed", status: status, reason: "", receivedAt: receivedAt,
                              authorization: path.map {
                                  ProviderAuthorizationStatus(appAttestAvailable: true, path: $0, expiresAt: expiresAt,
                                                              sessionID: "s", machineID: "m") })
        }
        func refuses(connectedAt: Double, _ trust: DaemonState.Trust?, requestAt: Double? = nil) -> Bool {
            let connection = DaemonState.CoordinatorConnection(
                connected: true, since: connectedAt, connections: 1, lastRequestAt: requestAt)
            if case .blocked? = ServingReadiness.verdict(connection: connection, trust: trust, now: now) { return true }
            return false
        }
        // No status long after connecting: never confirmed.
        #expect(refuses(connectedAt: now - 600, nil))
        #expect(!refuses(connectedAt: now - 10, nil))
        #expect(refuses(connectedAt: now - 600, trust("none")))
        #expect(refuses(connectedAt: now - 600, trust("app_attest", expiresAt: now - 1)))
        #expect(!refuses(connectedAt: now - 600, trust("app_attest", expiresAt: now + 60)))
        #expect(!refuses(connectedAt: now - 600, trust("legacy")))
        // Without an authorization object (no App Attest serving) nothing is judged.
        #expect(!refuses(connectedAt: now - 600, trust(nil)))
        #expect(refuses(connectedAt: now - 600, trust(nil, status: "untrusted")))
        // A refusal counts only while current: not right after connecting, not
        // once the coordinator stopped repeating it, not before routed work.
        #expect(!refuses(connectedAt: now - 30, trust("none")))
        #expect(!refuses(connectedAt: now - 600, trust("none", receivedAt: now - ServingReadiness.refusalMaxAge - 1)))
        #expect(!refuses(connectedAt: now - 600, trust("none", receivedAt: now - 5), requestAt: now - 1))
        #expect(!refuses(connectedAt: now - 600, nil, requestAt: now - 1))
        // An expired lease and an explicit untrusted status do not go out of date.
        #expect(refuses(connectedAt: now - 9_000, trust("app_attest", expiresAt: now - 3_600, receivedAt: now - 7_200)))
        #expect(refuses(connectedAt: now - 9_000, trust(nil, status: "untrusted", receivedAt: now - 7_200)))
    }
}
