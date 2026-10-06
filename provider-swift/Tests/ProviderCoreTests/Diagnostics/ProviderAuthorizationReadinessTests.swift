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

    @Test func expiredStatusNeverClaimsThatRemovalIsAvailable() {
        let description = ProviderAuthorizationReadiness.summary(
            status(expiresAt: 100), enrollment: .enrolledDarkbloom(serverURL: darkbloomServerURL), now: 100)
        #expect(!description.contains("removal is available"))
        #expect(description.contains("not currently qualified"))
    }

    @Test func disabledCoordinatorLeavesMacOS27SetupPendingWithoutMDMFallback() {
        var disabled = status(path: "none")
        disabled.appAttestAvailable = false
        let summary = ProviderAuthorizationReadiness.summary(
            disabled, enrollment: .enrolledDarkbloom(serverURL: darkbloomServerURL), now: 100,
            macOSMajorVersion: 27)
        #expect(summary.contains("setup remains pending"))
        #expect(!summary.contains("enrollment is still required"))
        #expect(!ProviderAuthorizationReadiness.removalReady(disabled, now: 100))
    }

    // MARK: - Local enrollment guidance

    private let darkbloomServerURL = "https://api.darkbloom.dev/mdm/connect"
    private let otherMDMServerURL = "https://mdm.example.org/mdm/commands"

    private func summary(_ enrollment: MDMEnrollmentState) -> String {
        ProviderAuthorizationReadiness.summary(status(), enrollment: enrollment, now: 100)
    }

    @Test func removalIsOfferedOnlyWhenTheDarkbloomProfileIsInstalled() {
        let description = summary(.enrolledDarkbloom(serverURL: darkbloomServerURL))
        #expect(description.contains("App Attest authorizes this connection."))
        #expect(description.contains("Darkbloom MDM removal is available: run darkbloom unenroll and choose option 2."))
        #expect(description.contains("Keep any organization management profiles installed."))
        #expect(description.contains("Base rewards have separate eligibility checks."))
    }

    @Test func otherMDMIsNeverToldToRemoveManagement() {
        let description = summary(.enrolledOtherMDM(serverURL: otherMDMServerURL))
        #expect(description.contains("App Attest authorizes this connection."))
        #expect(description.contains("No Darkbloom MDM profile is installed"))
        #expect(description.contains("keep that profile installed"))
        #expect(description.contains(otherMDMServerURL))
        #expect(!description.contains("removal is available"))
        #expect(!description.contains("darkbloom unenroll"))
    }

    @Test func unenrolledMacIsNotOfferedARemovalItCannotPerform() {
        let none = summary(.notEnrolled)
        #expect(none.contains("App Attest authorizes this connection."))
        #expect(none.contains("no action is needed"))
        #expect(none.contains("Keep the provider running."))
        #expect(none.contains("Base rewards have separate eligibility checks."))
        #expect(!none.contains("removal is available"))
        #expect(!none.contains("darkbloom unenroll"))
    }

    @Test func unreadableProfileInventoryWithholdsRemovalGuidance() {
        let unknown = summary(.checkFailed)
        #expect(unknown.contains("could not be read"))
        #expect(unknown.contains("keep existing profiles installed"))
        #expect(!unknown.contains("removal is available"))
        #expect(!unknown.contains("darkbloom unenroll"))
    }

    @Test func rolloutFlagStillGatesEnrolledDarkbloomMachines() {
        var notEnabled = status()
        notEnabled.mdmRemovalReady = false
        let summary = ProviderAuthorizationReadiness.summary(
            notEnabled, enrollment: .enrolledDarkbloom(serverURL: darkbloomServerURL), now: 100)
        #expect(summary.contains("coordinator has not enabled Darkbloom MDM removal"))
        #expect(summary.contains("Keep the Darkbloom MDM profile installed."))
        #expect(!summary.contains("removal is available"))
        #expect(!summary.contains("darkbloom unenroll"))
    }

    @Test func noEnrollmentStateAdvertisesRemovalWithoutACurrentLease() {
        for enrollment: MDMEnrollmentState in [
            .enrolledDarkbloom(serverURL: darkbloomServerURL), .enrolledOtherMDM(serverURL: otherMDMServerURL),
            .notEnrolled, .checkFailed,
        ] {
            let expired = ProviderAuthorizationReadiness.summary(
                status(expiresAt: 100), enrollment: enrollment, now: 100)
            #expect(!expired.contains("removal is available"))
            #expect(!expired.contains("darkbloom unenroll"))
            let missing = ProviderAuthorizationReadiness.summary(
                nil, enrollment: enrollment, now: 100)
            #expect(!missing.contains("removal is available"))
            #expect(!missing.contains("darkbloom unenroll"))
        }
    }

    @Test func legacyServingDoesNotImplyBaseRewardEligibility() {
        let description = ProviderAuthorizationReadiness.summary(
            status(path: "legacy"), enrollment: .enrolledDarkbloom(serverURL: darkbloomServerURL), now: 100)
        #expect(description.contains("Serving through legacy verification"))
        #expect(description.contains("keep the Darkbloom MDM profile"))
        #expect(description.contains("Legacy verification alone does not qualify for base rewards."))
        #expect(!description.contains("darkbloom unenroll"))
    }
}
