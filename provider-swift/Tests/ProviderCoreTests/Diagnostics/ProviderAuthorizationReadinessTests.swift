import Foundation
import Testing
@testable import ProviderCore

@Suite struct ProviderAuthorizationReadinessTests {
    private func status(path: String = "app_attest", expiresAt: Double = 130) -> ProviderAuthorizationStatus {
        ProviderAuthorizationStatus(appAttestAvailable: true, path: path,
                                    expiresAt: expiresAt,
                                    sessionID: "current-session", machineID: "stable-machine")
    }

    @Test func onlyAValidUnexpiredLeaseIsAnAppAttestGrant() {
        #expect(status().hasCurrentAppAttestAuthorization(now: 100))
        #expect(!status(path: "none").hasCurrentAppAttestAuthorization(now: 100))
        #expect(!status(path: "legacy").hasCurrentAppAttestAuthorization(now: 100))
        #expect(!status(expiresAt: 100).hasCurrentAppAttestAuthorization(now: 100))
        #expect(!status(expiresAt: .nan).hasCurrentAppAttestAuthorization(now: 100))
        #expect(!status(expiresAt: .infinity).hasCurrentAppAttestAuthorization(now: 100))
        var invalid = status()
        invalid.sessionID = ""
        #expect(!invalid.hasCurrentAppAttestAuthorization(now: 100))
        invalid = status()
        invalid.machineID = ""
        #expect(!invalid.hasCurrentAppAttestAuthorization(now: 100))
        invalid = status()
        invalid.protocolVersion = 2
        #expect(!invalid.hasCurrentAppAttestAuthorization(now: 100))
    }

    @Test func onlyTheCurrentConnectionAndProcessAreShown() {
        func shown(writtenAt: Double = 100, receivedAt: Double = 99,
                   processMatches: Bool = true, coordinatorMatches: Bool = true,
                   online: String = "online") -> ProviderAuthorizationStatus? {
            ProviderAuthorizationReadiness.displayedStatus(
                status(), status: online, writtenAt: writtenAt, receivedAt: receivedAt,
                startedAt: 90, now: 100, processMatches: processMatches,
                coordinatorMatches: coordinatorMatches)
        }
        #expect(shown() != nil)
        #expect(shown(writtenAt: 89) == nil)
        #expect(shown(writtenAt: 110) == nil)
        #expect(shown(receivedAt: 89) == nil)
        #expect(shown(receivedAt: 110) == nil)
        #expect(shown(processMatches: false) == nil)
        #expect(shown(coordinatorMatches: false) == nil)
        #expect(shown(online: "untrusted") == nil)
        #expect(shown(online: "offline") == nil)
    }

    @Test func stateRoundTripPreservesCoordinatorAndAuthorization() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let identity = ProcessIdentity(pid: 41, startTimeMicros: 9)
        let original = DaemonState(pid: 41, processIdentity: identity, version: "test",
                                   writtenAt: 100, startedAt: 90,
                                   trust: .init(trustLevel: "self_signed", status: "online", reason: "",
                                                receivedAt: 99, authorization: status()),
                                   coordinatorURL: "wss://api.darkbloom.dev/ws/provider")
        DaemonStateFile.write(original, to: url)
        let read = try #require(DaemonStateFile.read(from: url))
        #expect(read == original)
        #expect(read.displayedProviderAuthorization(coordinatorURL: "https://api.darkbloom.dev", now: 100,
                                                    readProcessIdentity: { _ in identity }) == status())
        #expect(read.displayedProviderAuthorization(coordinatorURL: "https://other.example", now: 100,
                                                    readProcessIdentity: { _ in identity }) == nil)
        #expect(read.displayedProviderAuthorization(coordinatorURL: "https://api.darkbloom.dev", now: 100,
                                                    readProcessIdentity: { _ in nil }) == nil)
    }

    /// A renewal older than `snapshotMaxAge` is still the coordinator's
    /// grant until `expiresAt`; status and doctor must not drop to legacy trust.
    @Test func displayKeepsAnUnexpiredLeaseWhoseRenewalIsLate() {
        let identity = ProcessIdentity(pid: 41, startTimeMicros: 9)
        func state(receivedAt: Double, expiresAt: Double, path: String = "app_attest",
                   online: String = "online") -> DaemonState {
            DaemonState(
                pid: 41, processIdentity: identity, version: "test",
                writtenAt: 100, startedAt: 50,
                trust: .init(trustLevel: "self_signed", status: online, reason: "",
                             receivedAt: receivedAt, authorization: status(path: path, expiresAt: expiresAt)),
                coordinatorURL: "wss://api.darkbloom.dev/ws/provider")
        }
        func displayed(_ state: DaemonState, coordinator: String = "https://api.darkbloom.dev",
                       identity: ProcessIdentity? = identity, now: Double = 100) -> ProviderAuthorizationStatus? {
            state.displayedProviderAuthorization(
                coordinatorURL: coordinator, now: now, readProcessIdentity: { _ in identity })
        }
        let late = state(receivedAt: 85, expiresAt: 115)
        #expect(displayed(late) == late.trust?.authorization)

        #expect(displayed(state(receivedAt: 85, expiresAt: 100)) == nil)
        #expect(displayed(state(receivedAt: 85, expiresAt: 115, path: "none")) == nil)
        #expect(displayed(state(receivedAt: 40, expiresAt: 115)) == nil)
        #expect(displayed(late, coordinator: "https://other.example") == nil)
        #expect(displayed(late, identity: nil) == nil)
        #expect(displayed(state(receivedAt: 85, expiresAt: 115, online: "untrusted")) == nil)
        // The lease cannot outlive a daemon that stopped writing its snapshot.
        #expect(displayed(late, now: 110.001) == nil)
    }

    @Test func expiredStatusIsNotAGrant() {
        let description = ProviderAuthorizationReadiness.summary(status(expiresAt: 100), now: 100)
        #expect(!description.contains("App Attest authorizes"))
        #expect(description.contains("not currently qualified"))
    }

    /// No decision or lease state sends the operator to a coordinator
    /// readiness gate or names MDM.
    @Test func summaryNeverGatesOrKeepsTheRetiredProfile() {
        let cli = BuildEnvironment.current.cliName
        var disabled = status(path: "none")
        disabled.appAttestAvailable = false
        let decisions: [ProviderAuthorizationStatus?] = [
            nil, status(), status(expiresAt: 100), status(path: "none"), status(path: "legacy"), disabled,
        ]
        for authorization in decisions {
            for macOS in [26, 27] {
                let summary = ProviderAuthorizationReadiness.summary(authorization, now: 100, macOSMajorVersion: macOS)
                #expect(!summary.contains("removal"), "\(summary)")
                #expect(!summary.contains("readiness"), "\(summary)")
                #expect(!summary.contains("MDM"), "\(summary)")
                #expect(!summary.contains("management profiles installed"), "\(summary)")
                #expect(!summary.contains("\(cli) enroll"), "\(summary)")
            }
        }
        #expect(ProviderAuthorizationReadiness.summary(status(), now: 100) == "App Attest authorizes this connection.")
    }

    @Test func legacyServingSaysItIsRetiredAndHowToKeepServing() {
        let old = ProviderAuthorizationReadiness.summary(status(path: "legacy"), now: 100, macOSMajorVersion: 26)
        #expect(old.contains("legacy verification, which Darkbloom has retired"))
        #expect(old.contains("macOS 27 or later"))
        let current = ProviderAuthorizationReadiness.summary(status(path: "legacy"), now: 100, macOSMajorVersion: 27)
        #expect(current.contains("Serving continues only with App Attest authorization"))
    }

    @Test func displayKeepsItsTimeBoundaries() {
        func shown(receivedAt: Double = 90, expiresAt: Double = 115,
                   writtenAt: Double = 100) -> ProviderAuthorizationStatus? {
            ProviderAuthorizationReadiness.displayedStatus(
                status(expiresAt: expiresAt), status: "online", writtenAt: writtenAt, receivedAt: receivedAt,
                startedAt: 50, now: 100, processMatches: true, coordinatorMatches: true)
        }
        #expect(shown() != nil)
        #expect(shown(receivedAt: 89.999) != nil)
        #expect(shown(receivedAt: 85, expiresAt: 100) == nil)
        #expect(shown(receivedAt: 85, expiresAt: 100.001) != nil)
        for expiry in [Double.nan, .infinity] {
            #expect(shown(receivedAt: 85, expiresAt: expiry) == nil)
        }
        #expect(shown(writtenAt: 89.999) == nil)
        #expect(shown(writtenAt: 102.001) == nil)
    }

    @Test func missingOrExpiredAuthorizationIsNeverAGrant() {
        let unavailable: [ProviderAuthorizationStatus?] = [nil, status(expiresAt: 100), status(path: "none")]
        for displayed in unavailable {
            let summary = ProviderAuthorizationReadiness.summary(displayed, now: 100)
            #expect(!summary.contains("App Attest authorizes this connection"))
        }
    }

    @Test func disabledCoordinatorLeavesMacOS27SetupPendingWithoutFallback() {
        var disabled = status(path: "none")
        disabled.appAttestAvailable = false
        let summary = ProviderAuthorizationReadiness.summary(disabled, now: 100, macOSMajorVersion: 27)
        #expect(summary.contains("setup remains pending"))
        #expect(summary.contains("check `\(BuildEnvironment.current.cliName) doctor`"))
        #expect(!summary.contains("enrollment is still required"))
    }

    // MARK: - Last-reported history (none and legacy past snapshotMaxAge)

    /// Defaults describe a fresh snapshot (written at `now`) holding a
    /// coordinator decision received 600 s earlier by the same process.
    private func lastReported(
        _ authorization: ProviderAuthorizationStatus?, writtenAt: Double = 1000,
        receivedAt: Double = 400, startedAt: Double = 300, now: Double = 1000,
        processMatches: Bool = true, coordinatorMatches: Bool = true,
        online: String? = "online"
    ) -> ProviderAuthorizationStatus? {
        ProviderAuthorizationReadiness.lastReportedStatus(
            authorization, status: online, writtenAt: writtenAt, receivedAt: receivedAt,
            startedAt: startedAt, now: now, processMatches: processMatches,
            coordinatorMatches: coordinatorMatches)
    }

    private func displayed(
        _ authorization: ProviderAuthorizationStatus?, receivedAt: Double = 400
    ) -> ProviderAuthorizationStatus? {
        ProviderAuthorizationReadiness.displayedStatus(
            authorization, status: "online", writtenAt: 1000, receivedAt: receivedAt,
            startedAt: 300, now: 1000, processMatches: true, coordinatorMatches: true)
    }

    @Test func agedDeniedAndLegacyDecisionsAreShownOnlyAsHistory() {
        for path in ["none", "legacy"] {
            // An unexpired lease is set on purpose: it may not turn history
            // into a grant.
            let reported = status(path: path, expiresAt: 2000)
            for receivedAt in [989.999, 400, 300] {
                #expect(displayed(reported, receivedAt: receivedAt) == nil)
                #expect(lastReported(reported, receivedAt: receivedAt) == reported)
            }
        }
    }

    @Test func aReportTheDisplayShowsIsNeverAlsoHistory() {
        // A fresh receipt of any path is the displayed decision.
        for path in ["app_attest", "none", "legacy", "unrecognised"] {
            let reported = status(path: path, expiresAt: 2000)
            for receivedAt in [990.0, 999, 1002] {
                #expect(displayed(reported, receivedAt: receivedAt) == reported)
                #expect(lastReported(reported, receivedAt: receivedAt) == nil)
            }
        }
    }

    @Test func agedAppAttestDecisionIsNeverHistory() {
        // An unexpired lease is still displayed as the grant; an expired one
        // is shown nowhere.
        for expiresAt in [2000.0, 999] {
            let attest = status(expiresAt: expiresAt)
            for receivedAt in [989.999, 400, 300] {
                #expect(lastReported(attest, receivedAt: receivedAt) == nil)
                #expect((displayed(attest, receivedAt: receivedAt) != nil) == (expiresAt == 2000))
            }
        }
    }

    @Test func agedUnknownPathIsNeverShown() {
        for path in ["unrecognised", "", "LEGACY", "none ", "self_route"] {
            #expect(lastReported(status(path: path, expiresAt: 2000)) == nil)
        }
    }

    @Test func historyKeepsTheSnapshotWriteLimitAtTenSeconds() {
        let denied = status(path: "none")
        #expect(lastReported(denied, writtenAt: 990) == denied)
        // 20 s is stale here even though the daemon-state file is not treated
        // as stale elsewhere until 90 s.
        for writtenAt in [989.999, 980, 940, 910] {
            #expect(lastReported(denied, writtenAt: writtenAt) == nil)
        }
        #expect(lastReported(denied, writtenAt: 1002) == denied)
        #expect(lastReported(denied, writtenAt: 1003) == nil)
    }

    @Test func historyKeepsIdentityStatusAndProtocolGuards() {
        var unknownProtocol = status(path: "none")
        unknownProtocol.protocolVersion = 2
        for path in ["none", "legacy"] {
            let reported = status(path: path)
            #expect(lastReported(reported, processMatches: false) == nil)
            #expect(lastReported(reported, coordinatorMatches: false) == nil)
            #expect(lastReported(reported, online: "offline") == nil)
            #expect(lastReported(reported, online: "untrusted") == nil)
            #expect(lastReported(reported, online: nil) == nil)
        }
        #expect(lastReported(unknownProtocol) == nil)
        #expect(lastReported(nil) == nil)
    }

    @Test func historyKeepsTimestampGuards() {
        let denied = status(path: "none")
        // A future receipt, and a receipt from before this process started.
        #expect(lastReported(denied, receivedAt: 1002.001) == nil)
        #expect(lastReported(denied, receivedAt: 1003) == nil)
        #expect(lastReported(denied, receivedAt: 299.999) == nil)
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(lastReported(denied, receivedAt: bad) == nil)
            #expect(lastReported(denied, writtenAt: bad) == nil)
            #expect(lastReported(denied, startedAt: bad) == nil)
            #expect(lastReported(denied, now: bad) == nil)
        }
    }

    @Test func stateHistoryUsesTheSameProcessAndCoordinatorBinding() {
        let identity = ProcessIdentity(pid: 41, startTimeMicros: 9)
        func daemonState(_ authorization: ProviderAuthorizationStatus?, writtenAt: Double = 1000,
                         receivedAt: Double = 400, online: String = "online") -> DaemonState {
            DaemonState(pid: 41, processIdentity: identity, version: "test",
                        writtenAt: writtenAt, startedAt: 300,
                        trust: .init(trustLevel: "self_signed", status: online, reason: "",
                                     receivedAt: receivedAt, authorization: authorization),
                        coordinatorURL: "wss://api.darkbloom.dev/ws/provider")
        }
        func shown(_ state: DaemonState, coordinator: String = "https://api.darkbloom.dev",
                   kernelReports read: (ProcessIdentity?)? = nil) -> ProviderAuthorizationStatus? {
            let reported = read ?? identity
            return state.lastReportedProviderAuthorization(
                coordinatorURL: coordinator, now: 1000, readProcessIdentity: { _ in reported })
        }
        for path in ["none", "legacy"] {
            let reported = status(path: path, expiresAt: 2000)
            let aged = daemonState(reported)
            #expect(aged.displayedProviderAuthorization(
                coordinatorURL: "https://api.darkbloom.dev", now: 1000,
                readProcessIdentity: { _ in identity }) == nil)
            #expect(shown(aged) == reported)
            #expect(shown(aged, coordinator: "https://other.example") == nil)
            // The daemon is gone, then a reused PID with another start time.
            #expect(shown(aged, kernelReports: .some(nil)) == nil)
            #expect(shown(aged, kernelReports: ProcessIdentity(pid: 41, startTimeMicros: 10)) == nil)
            var unidentified = aged
            unidentified.processIdentity = nil
            #expect(shown(unidentified) == nil)
            #expect(shown(daemonState(reported, writtenAt: 980)) == nil)
            #expect(shown(daemonState(reported, receivedAt: 299)) == nil)
            #expect(shown(daemonState(reported, online: "offline")) == nil)
            // Received just now: the displayed decision, never history.
            #expect(shown(daemonState(reported, receivedAt: 999)) == nil)
        }
        #expect(shown(daemonState(status(expiresAt: 2000))) == nil)
        #expect(shown(daemonState(status(path: "unrecognised"))) == nil)
        #expect(shown(daemonState(nil)) == nil)
    }

    @Test func lastReportedSummaryStatesItsAgeAndNeverClaimsAGrant() {
        func text(_ authorization: ProviderAuthorizationStatus, receivedAt: Double = 400) -> String {
            ProviderAuthorizationReadiness.lastReportedSummary(
                authorization, receivedAt: receivedAt, now: 1000, macOSMajorVersion: 27)
        }
        let legacy = text(status(path: "legacy", expiresAt: 2000))
        #expect(legacy.hasPrefix("received 10m ago; not a fresh dispatch grant. "))
        #expect(legacy.contains("legacy verification"))
        let denied = text(status(path: "none", expiresAt: 2000))
        #expect(denied.hasPrefix("received 10m ago; not a fresh dispatch grant. "))
        #expect(denied.contains("not currently qualified"))
        // An App Attest or unknown record handed in by mistake reads as
        // unconfirmed rather than as an authorization.
        for path in ["app_attest", "unrecognised"] {
            let other = text(status(path: path, expiresAt: 2000), receivedAt: 999)
            #expect(other.contains("unconfirmed"))
            #expect(!other.contains("App Attest authorizes"))
        }
        for summary in [legacy, denied, text(status(expiresAt: 2000), receivedAt: 999)] {
            #expect(!summary.contains("removal is available"))
            #expect(!summary.contains("App Attest authorizes"))
        }
        #expect(text(status(path: "none"), receivedAt: 988).hasPrefix("received 12s ago; "))
        #expect(text(status(path: "none"), receivedAt: 1002).hasPrefix("received 0s ago; "))
        #expect(text(status(path: "none"), receivedAt: 1000 - 259_200).hasPrefix("received 72h ago; "))
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(text(status(path: "none"), receivedAt: bad).hasPrefix("received at an unknown time; "))
        }
    }
}
