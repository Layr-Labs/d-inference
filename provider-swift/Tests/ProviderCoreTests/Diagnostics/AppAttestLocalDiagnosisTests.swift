import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

private func check(_ diags: [Diagnostic], _ name: String) -> Diagnostic? {
    diags.first { $0.name == name }
}

private func status(session: AppAttestLaunchSession = .gui, reason: AppAttestAvailabilityReason? = nil,
                    stalled: Int? = nil, key: AppAttestKeyState? = AppAttestKeyState(recordPresent: true, attested: true, generationBlockedUntil: nil)) -> AppAttestLocalStatus {
    AppAttestLocalStatus(observedAt: 100, launchSession: session, bootTime: 50,
                         availabilityReason: reason, operationStalledSeconds: stalled, key: key)
}

@Suite("App Attest doctor diagnosis")
struct AppAttestLocalDiagnosisTests {
    @Test func belowMacOS27ReportsNothing() {
        #expect(AppAttestLocalDiagnosis.evaluate(status(), daemonRunning: true, macOSMajorVersion: 26, now: 100).isEmpty)
    }

    @Test func healthyGuiProviderWithEnrolledKeyPasses() {
        let d = AppAttestLocalDiagnosis.evaluate(status(), daemonRunning: true, macOSMajorVersion: 27, now: 100)
        #expect(d.allSatisfy { $0.section == .appAttest && $0.level == .pass })
        #expect(check(d, "launch session") != nil)
        #expect(check(d, "app attest key")?.message.contains("enrolled with Apple") == true)
    }

    @Test func isSupportedFalseFromBackgroundSessionFailsWithTargetedAdvice() {
        let d = AppAttestLocalDiagnosis.evaluate(status(session: .background, reason: .isSupportedFalse, key: nil),
                                                 daemonRunning: true, macOSMajorVersion: 27, now: 100)
        #expect(check(d, "launch session")?.level == .warn)
        let support = check(d, "app attest support")
        #expect(support?.level == .fail)
        #expect(support?.message.contains("outside the logged-in GUI session") == true)
        for advice in ["logged-in GUI session", "csrutil status", "Full Security"] {
            #expect(support?.fix?.contains(advice) == true, "missing advice: \(advice)")
        }
        #expect(check(d, "app attest key") == nil, "unavailable App Attest has no key state to report")
    }

    @Test func otherAvailabilityReasonsFailWithoutGuiAdvice() {
        let d = AppAttestLocalDiagnosis.evaluate(status(reason: .notAppBundle, key: nil),
                                                 daemonRunning: true, macOSMajorVersion: 27, now: 100)
        let support = check(d, "app attest support")
        #expect(support?.level == .fail)
        #expect(support?.message.contains("not_app_bundle") == true)
        #expect(support?.fix?.contains("GUI session") == false)
    }

    @Test func unreadableKeychainIsNotReportedAsHealthy() {
        let d = AppAttestLocalDiagnosis.evaluate(status(key: nil), daemonRunning: true, macOSMajorVersion: 27, now: 100)
        #expect(check(d, "app attest key")?.level == .warn)
        #expect(check(d, "app attest key")?.message.contains("Keychain") == true)
    }

    @Test func stalledAppleOperationWarnsAndExplainsAutomaticRestart() {
        let d = AppAttestLocalDiagnosis.evaluate(status(stalled: 5400), daemonRunning: true, macOSMajorVersion: 27, now: 100)
        let stall = check(d, "apple operation")
        #expect(stall?.level == .warn)
        #expect(stall?.message.contains("1h30m") == true)
        #expect(stall?.message.contains("6 h") == true)
    }

    @Test func generationCooldownIsReportedUntilItExpires() {
        let blocked = AppAttestKeyState(recordPresent: false, attested: false, generationBlockedUntil: 100 + 1800)
        let during = AppAttestLocalDiagnosis.evaluate(status(key: blocked), daemonRunning: true, macOSMajorVersion: 27, now: 100)
        #expect(check(during, "app attest key")?.level == .warn)
        #expect(check(during, "app attest key")?.message.contains("30m") == true)
        let after = AppAttestLocalDiagnosis.evaluate(status(key: blocked), daemonRunning: true, macOSMajorVersion: 27, now: 100 + 1801)
        #expect(check(after, "app attest key")?.level == .pass)
    }

    @Test func missingDaemonOrObservationWarnsWithoutGuessing() {
        let stopped = AppAttestLocalDiagnosis.evaluate(status(), daemonRunning: false, macOSMajorVersion: 27, now: 100)
        #expect(stopped.count == 1 && stopped[0].level == .warn && stopped[0].fix?.contains("darkbloom start") == true)
        let pending = AppAttestLocalDiagnosis.evaluate(nil, daemonRunning: true, macOSMajorVersion: 27, now: 100)
        #expect(pending.count == 1 && pending[0].level == .warn)
    }

    @Test func daemonStateRoundTripsLocalStatusAndOlderFilesStillDecode() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let local = status(session: .background, reason: .isSupportedFalse, stalled: 901,
                           key: AppAttestKeyState(recordPresent: false, attested: false, generationBlockedUntil: 200))
        DaemonStateFile.write(DaemonState(pid: 1, version: "t", writtenAt: 1, startedAt: 1, appAttest: local), to: url)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"launch_session\":\"background\"") && raw.contains("\"generation_blocked_until\":200"))
        #expect(DaemonStateFile.read(from: url)?.appAttest == local)

        DaemonStateFile.write(DaemonState(pid: 1, version: "t", writtenAt: 1, startedAt: 1), to: url)
        #expect(DaemonStateFile.read(from: url)?.appAttest == nil)
        #expect(DaemonStateFile.read(from: url)?.pid == 1)
    }
}
