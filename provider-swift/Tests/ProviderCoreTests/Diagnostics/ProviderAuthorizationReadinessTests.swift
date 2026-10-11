import Foundation
import Testing
@testable import ProviderCore

@Suite struct ProviderAuthorizationReadinessTests {
    private func status(path: String = "app_attest", expiresAt: Double = 130) -> ProviderAuthorizationStatus {
        ProviderAuthorizationStatus(appAttestAvailable: true, path: path,
                                    expiresAt: expiresAt, mdmRemovalReady: true,
                                    sessionID: "current-session", machineID: "stable-machine")
    }

    @Test func capabilityAndEnrollmentAreNotAuthorization() {
        #expect(!ProviderAuthorizationReadiness.removalReady(nil, now: 100))
        #expect(!ProviderAuthorizationReadiness.removalReady(status(path: "none"), now: 100))
        #expect(!ProviderAuthorizationReadiness.removalReady(status(path: "legacy"), now: 100))
        #expect(ProviderAuthorizationReadiness.removalReady(status(), now: 100))
        var notEnabled = status()
        notEnabled.mdmRemovalReady = false
        #expect(!ProviderAuthorizationReadiness.removalReady(notEnabled, now: 100))
    }

    @Test func expiryAndIdentityFieldsAreRequired() {
        #expect(!ProviderAuthorizationReadiness.removalReady(status(expiresAt: 100), now: 100))
        #expect(!ProviderAuthorizationReadiness.removalReady(status(expiresAt: .nan), now: 100))
        #expect(!ProviderAuthorizationReadiness.removalReady(status(expiresAt: .infinity), now: 100))
        var invalid = status()
        invalid.sessionID = ""
        #expect(!ProviderAuthorizationReadiness.removalReady(invalid, now: 100))
        invalid = status()
        invalid.machineID = ""
        #expect(!ProviderAuthorizationReadiness.removalReady(invalid, now: 100))
        invalid = status()
        invalid.protocolVersion = 2
        #expect(!ProviderAuthorizationReadiness.removalReady(invalid, now: 100))
    }

    @Test func onlyCurrentConnectionAndProcessCanOfferMigration() {
        func current(writtenAt: Double = 100, receivedAt: Double = 99,
                     processMatches: Bool = true, coordinatorMatches: Bool = true,
                     online: String = "online") -> ProviderAuthorizationStatus? {
            ProviderAuthorizationReadiness.currentStatus(
                status(), status: online, writtenAt: writtenAt, receivedAt: receivedAt,
                startedAt: 90, now: 100, processMatches: processMatches,
                coordinatorMatches: coordinatorMatches)
        }
        #expect(current() != nil)
        #expect(current(writtenAt: 89) == nil)
        #expect(current(writtenAt: 110) == nil)
        #expect(current(receivedAt: 89) == nil)
        #expect(current(receivedAt: 110) == nil)
        #expect(current(processMatches: false) == nil)
        #expect(current(coordinatorMatches: false) == nil)
        #expect(current(online: "untrusted") == nil)
        #expect(current(online: "offline") == nil)
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
        #expect(read.currentProviderAuthorization(coordinatorURL: "https://api.darkbloom.dev", now: 100,
                                                  readProcessIdentity: { _ in identity }) == status())
        #expect(read.currentProviderAuthorization(coordinatorURL: "https://other.example", now: 100,
                                                  readProcessIdentity: { _ in identity }) == nil)
        #expect(read.currentProviderAuthorization(coordinatorURL: "https://api.darkbloom.dev", now: 100,
                                                  readProcessIdentity: { _ in nil }) == nil)
    }

    @Test func daemonWritesCannotRefreshAnOldRemovalDecision() {
        let identity = ProcessIdentity(pid: 41, startTimeMicros: 9)
        func current(receivedAt: Double) -> ProviderAuthorizationStatus? {
            let state = DaemonState(
                pid: 41, processIdentity: identity, version: "test",
                writtenAt: 100, startedAt: 50,
                trust: .init(trustLevel: "self_signed", status: "online", reason: "",
                             receivedAt: receivedAt, authorization: status(expiresAt: 120)),
                coordinatorURL: "wss://api.darkbloom.dev/ws/provider")
            return state.currentProviderAuthorization(
                coordinatorURL: "https://api.darkbloom.dev", now: 100,
                readProcessIdentity: { _ in identity })
        }
        // The file is freshly written and the lease has time left, but an
        // old decision must not authorize removal after a delayed revocation.
        for receivedAt in [89.999, 80, 50] {
            #expect(current(receivedAt: receivedAt) == nil)
            #expect(!ProviderAuthorizationReadiness.removalReady(current(receivedAt: receivedAt), now: 100))
        }
        #expect(ProviderAuthorizationReadiness.removalReady(current(receivedAt: 90), now: 100))
        #expect(ProviderAuthorizationReadiness.removalReady(current(receivedAt: 99), now: 100))
    }

    /// The coordinator renews a ~30 s App Attest lease every few seconds with
    /// jitter. A renewal older than `snapshotMaxAge` is still the coordinator's
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
        // Unenroll keeps requiring a renewal inside snapshotMaxAge.
        #expect(late.currentProviderAuthorization(
            coordinatorURL: "https://api.darkbloom.dev", now: 100, readProcessIdentity: { _ in identity }) == nil)

        #expect(displayed(state(receivedAt: 85, expiresAt: 100)) == nil)
        #expect(displayed(state(receivedAt: 85, expiresAt: 115, path: "none")) == nil)
        #expect(displayed(state(receivedAt: 40, expiresAt: 115)) == nil)
        #expect(displayed(late, coordinator: "https://other.example") == nil)
        #expect(displayed(late, identity: nil) == nil)
        #expect(displayed(state(receivedAt: 85, expiresAt: 115, online: "untrusted")) == nil)
        // The lease cannot outlive a daemon that stopped writing its snapshot.
        #expect(displayed(late, now: 110.001) == nil)
    }

    @Test func expiredStatusNeverClaimsThatRemovalIsAvailable() {
        let expired = status(expiresAt: 100)
        let description = ProviderAuthorizationReadiness.summary(
            expired, removalAuthorization: expired, now: 100)
        #expect(!description.contains("removal is available"))
        #expect(description.contains("not currently qualified"))
    }

    @Test func lateLeaseDoesNotOfferRemovalWithoutFreshReadiness() throws {
        let identity = ProcessIdentity(pid: 41, startTimeMicros: 9)
        let state = DaemonState(
            pid: 41, processIdentity: identity, version: "test",
            writtenAt: 100, startedAt: 50,
            trust: .init(trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
                         receivedAt: 85, authorization: status(expiresAt: 115)),
            coordinatorURL: "wss://fixture.invalid/ws/provider")
        let displayed = try #require(state.displayedProviderAuthorization(
            coordinatorURL: "https://fixture.invalid", now: 100, readProcessIdentity: { _ in identity }))
        let current = state.currentProviderAuthorization(
            coordinatorURL: "https://fixture.invalid", now: 100, readProcessIdentity: { _ in identity })
        #expect(current == nil)
        #expect(!ProviderAuthorizationReadiness.removalReady(current, now: 100))
        // This is the production summary called by status and both doctor paths.
        let summary = ProviderAuthorizationReadiness.summary(
            displayed, removalAuthorization: current, now: 100, macOSMajorVersion: 27)
        print("APP_ATTEST_LATE_LEASE_WITNESS displayed=\(displayed.path) fresh_removal=\(current != nil) summary=\(summary)")
        #expect(summary.contains("App Attest authorizes this connection"))
        #expect(!summary.contains("removal is available"))
        #expect(!summary.contains("run darkbloom unenroll"))
        #expect(summary.contains("needs fresh coordinator readiness"))
        #expect(summary.contains("keep existing management profiles installed"))
    }

    @Test func displayAndRemovalKeepTheirDistinctTimeBoundaries() {
        func decisions(receivedAt: Double = 90, expiresAt: Double = 115,
                       writtenAt: Double = 100) -> (ProviderAuthorizationStatus?, ProviderAuthorizationStatus?) {
            let authorization = status(expiresAt: expiresAt)
            return (
                ProviderAuthorizationReadiness.displayedStatus(
                    authorization, status: "online", writtenAt: writtenAt, receivedAt: receivedAt,
                    startedAt: 50, now: 100, processMatches: true, coordinatorMatches: true),
                ProviderAuthorizationReadiness.currentStatus(
                    authorization, status: "online", writtenAt: writtenAt, receivedAt: receivedAt,
                    startedAt: 50, now: 100, processMatches: true, coordinatorMatches: true))
        }
        #expect(decisions().0 != nil)
        #expect(ProviderAuthorizationReadiness.removalReady(decisions().1, now: 100))
        #expect(decisions(receivedAt: 89.999).0 != nil)
        #expect(decisions(receivedAt: 89.999).1 == nil)
        #expect(decisions(receivedAt: 85, expiresAt: 100).0 == nil)
        #expect(decisions(receivedAt: 85, expiresAt: 100.001).0 != nil)
        for expiry in [Double.nan, .infinity] {
            #expect(decisions(receivedAt: 85, expiresAt: expiry).0 == nil)
        }
        #expect(decisions(writtenAt: 89.999).0 == nil)
        #expect(decisions(writtenAt: 102.001).0 == nil)
    }

    @Test func summaryOffersRemovalOnlyWithinTheReceiptWindow() {
        for receivedAt in [90.0, 89.999] {
            let grant = status(expiresAt: 115)
            let displayed = ProviderAuthorizationReadiness.displayedStatus(
                grant, status: "online", writtenAt: 100, receivedAt: receivedAt,
                startedAt: 50, now: 100, processMatches: true, coordinatorMatches: true)
            let current = ProviderAuthorizationReadiness.currentStatus(
                grant, status: "online", writtenAt: 100, receivedAt: receivedAt,
                startedAt: 50, now: 100, processMatches: true, coordinatorMatches: true)
            let summary = ProviderAuthorizationReadiness.summary(
                displayed, removalAuthorization: current, now: 100)

            #expect(summary.contains("App Attest authorizes this connection"))
            #expect(summary.contains("removal is available") == (receivedAt == 90))
            #expect(summary.contains("run darkbloom unenroll") == (receivedAt == 90))
            #expect(summary.contains("needs fresh coordinator readiness") == (receivedAt == 89.999))
        }
    }

    @Test func summaryKeepsDisabledRemovalSeparateFromMissingReadiness() {
        var grant = status()
        grant.mdmRemovalReady = false
        for current: ProviderAuthorizationStatus? in [grant, nil] {
            let summary = ProviderAuthorizationReadiness.summary(
                grant, removalAuthorization: current, now: 100)
            #expect(summary.contains("App Attest authorizes this connection"))
            #expect(summary.contains("removal is not enabled"))
            #expect(!summary.contains("needs fresh coordinator readiness"))
            #expect(!summary.contains("run darkbloom unenroll"))
        }
    }

    @Test func summaryRejectsMissingOrDifferentRemovalDecisions() {
        let grant = status()
        var otherSession = grant
        otherSession.sessionID = "other-session"
        var otherMachine = grant
        otherMachine.machineID = "other-machine"
        var differentDecision = grant
        differentDecision.reason = "different-decision"
        var disabled = grant
        disabled.mdmRemovalReady = false
        var malformed = grant
        malformed.protocolVersion = 2
        let invalid: [ProviderAuthorizationStatus?] = [
            nil, otherSession, otherMachine, differentDecision, disabled, malformed,
            status(expiresAt: 100), status(path: "none"), status(path: "legacy"),
        ]
        for current in invalid {
            let summary = ProviderAuthorizationReadiness.summary(
                grant, removalAuthorization: current, now: 100)
            #expect(summary.contains("App Attest authorizes this connection"))
            #expect(summary.contains("needs fresh coordinator readiness"))
            #expect(summary.contains("keep existing management profiles installed"))
            #expect(!summary.contains("removal is available"))
            #expect(!summary.contains("run darkbloom unenroll"))
        }
    }

    @Test func removalDecisionCannotRestoreMissingOrExpiredDisplayedAuthorization() {
        let unavailable: [ProviderAuthorizationStatus?] = [nil, status(expiresAt: 100), status(path: "none")]
        for displayed in unavailable {
            let summary = ProviderAuthorizationReadiness.summary(
                displayed, removalAuthorization: status(), now: 100)
            #expect(!summary.contains("App Attest authorizes this connection"))
            #expect(!summary.contains("removal is available"))
            #expect(!summary.contains("run darkbloom unenroll"))
        }
    }

    @Test func disabledCoordinatorLeavesMacOS27SetupPendingWithoutMDMFallback() {
        var disabled = status(path: "none")
        disabled.appAttestAvailable = false
        let summary = ProviderAuthorizationReadiness.summary(
            disabled, removalAuthorization: disabled, now: 100, macOSMajorVersion: 27)
        #expect(summary.contains("setup remains pending"))
        #expect(!summary.contains("enrollment is still required"))
        #expect(!ProviderAuthorizationReadiness.removalReady(disabled, now: 100))
    }
}
