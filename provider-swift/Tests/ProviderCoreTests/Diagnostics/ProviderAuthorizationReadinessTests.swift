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

    @Test func expiredStatusNeverClaimsThatRemovalIsAvailable() {
        let description = ProviderAuthorizationReadiness.summary(status(expiresAt: 100), now: 100)
        #expect(!description.contains("removal is available"))
        #expect(description.contains("not currently qualified"))
    }
}
