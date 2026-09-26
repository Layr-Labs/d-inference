import Foundation
import ProviderAppAttest
import Testing
@testable import ProviderCore

private func check(_ diags: [Diagnostic], _ name: String) -> Diagnostic? {
    diags.first { $0.name == name }
}

private func status(session: AppAttestLaunchSession = .gui, process: AppAttestProcessDiagnostics? = nil,
                    history: AppAttestKeyHistory? = nil, failure: AppAttestLastAppleFailure? = nil) -> AppAttestLocalStatus {
    AppAttestLocalStatus(observedAt: 1_000, launchSession: session, bootTime: 50,
                         key: AppAttestKeyState(recordPresent: true, attested: true, generationBlockedUntil: nil),
                         process: process, keyHistory: history, lastAppleFailure: failure)
}

@Suite("App Attest deep doctor diagnosis")
struct AppAttestDeepDiagnosisTests {
    @Test func backgroundLaunchWithConsoleUserPointsAtSessionMismatch() {
        let d = AppAttestLocalDiagnosis.evaluate(
            status(session: .background, process: AppAttestProcessDiagnostics(consoleUserActive: true)),
            daemonRunning: true, macOSMajorVersion: 27, now: 1_000)
        let gui = check(d, "gui session")
        #expect(gui?.level == .warn)
        #expect(gui?.message.contains("launched outside that GUI session") == true)
        #expect(gui?.fix?.contains("darkbloom restart") == true)
    }

    @Test func bootSecurityRequiresBothPositiveReadings() {
        for sip in [nil, false, true] as [Bool?] {
            for root in [nil, false, true] as [Bool?] {
                let result = AppAttestDeepDiagnosis.bootSecurity(.init(sipEnabled: sip, authenticatedRoot: root))
                if sip == nil && root == nil { #expect(result == nil) }
                else if sip == false || root == false { #expect(result?.level == .fail) }
                else if sip == true && root == true { #expect(result?.level == .pass) }
                else { #expect(result?.level == .warn) }
            }
        }
    }

    @Test func bootSecurityFalseRequiresFullSecurity() {
        let d = AppAttestDeepDiagnosis.evaluate(
            status(process: AppAttestProcessDiagnostics(sipEnabled: false, authenticatedRoot: true)), pushHistory: nil, now: 1_000)
        let boot = check(d, "boot security")
        #expect(boot?.level == .fail)
        #expect(boot?.message.contains("Full Security") == true)
        let healthy = AppAttestDeepDiagnosis.evaluate(
            status(process: AppAttestProcessDiagnostics(sipEnabled: true, authenticatedRoot: true)), pushHistory: nil, now: 1_000)
        #expect(check(healthy, "boot security")?.level == .pass)
    }

    @Test(arguments: [
        AppAttestPreflight(optInEntitlement: true, environmentEntitlement: .production,
                          profilePresent: true, profileExpired: true),
        AppAttestPreflight(optInEntitlement: true, environmentEntitlement: .production, profilePresent: false),
        AppAttestPreflight(optInEntitlement: false, profilePresent: true),
        AppAttestPreflight(optInEntitlement: true, environmentEntitlement: .invalid, profilePresent: true),
    ])
    func knownInvalidSigningFailsEvenWhenOtherChecksAreUnknown(_ preflight: AppAttestPreflight) {
        let d = AppAttestDeepDiagnosis.evaluate(
            status(process: AppAttestProcessDiagnostics(preflight: preflight)), pushHistory: nil, now: 1_000)
        #expect(check(d, "app signing")?.level == .fail)
    }

    @Test(arguments: [
        AppAttestPreflight(profilePresent: true, bundlePathClass: .userInstall),
        AppAttestPreflight(environmentEntitlement: .production, profilePresent: true, profileExpired: false),
        AppAttestPreflight(optInEntitlement: true, profilePresent: true, profileExpired: false),
        AppAttestPreflight(optInEntitlement: true, environmentEntitlement: .production, profileExpired: false),
        AppAttestPreflight(optInEntitlement: true, environmentEntitlement: .production, profilePresent: true),
    ])
    func incompleteSigningEvidenceIsIndeterminate(_ preflight: AppAttestPreflight) {
        let d = AppAttestDeepDiagnosis.evaluate(
            status(process: AppAttestProcessDiagnostics(preflight: preflight)), pushHistory: nil, now: 1_000)
        #expect(check(d, "app signing")?.level == .warn)
    }

    @Test(arguments: [AppAttestPreflight.EnvironmentEntitlement.production, .development, .absent])
    func validSigningAllowsLegitimatelyAbsentEnvironment(_ environment: AppAttestPreflight.EnvironmentEntitlement) {
        let preflight = AppAttestPreflight(optInEntitlement: true, environmentEntitlement: environment,
                                          profilePresent: true, profileExpired: false, bundlePathClass: .userInstall)
        let d = AppAttestDeepDiagnosis.evaluate(
            status(process: AppAttestProcessDiagnostics(preflight: preflight)), pushHistory: nil, now: 1_000)
        #expect(check(d, "app signing")?.level == .pass)
    }

    @Test func undecodableSigningEvidenceNeverPasses() throws {
        let data = Data(#"{"opt_in_entitlement":"unknown","environment_entitlement":"future-value","profile_present":true,"profile_expired":"unknown"}"#.utf8)
        let preflight = try JSONDecoder().decode(AppAttestPreflight.self, from: data)
        let d = AppAttestDeepDiagnosis.evaluate(
            status(process: AppAttestProcessDiagnostics(preflight: preflight)), pushHistory: nil, now: 1_000)
        #expect(check(d, "app signing")?.level == .warn)
    }

    @Test func keyHistoryDisplayAgesAdvanceBetweenProofs() {
        let snapshot = status(history: AppAttestKeyHistory(lastSuccessAgeSeconds: 0, keyAgeSeconds: 30))
        let d = AppAttestLocalDiagnosis.evaluate(snapshot, daemonRunning: true, macOSMajorVersion: 27, now: 1_020)
        let history = check(d, "key history")
        #expect(history?.message.contains("last Apple success 20s ago") == true)
        #expect(history?.message.contains("current key 50s old") == true)
    }

    @Test func uncleanPreviousExitIsCalledOut() {
        let d = AppAttestDeepDiagnosis.evaluate(
            status(process: AppAttestProcessDiagnostics(previousExit: .unclean, startReason: .watchdog)), pushHistory: nil, now: 1_000)
        let start = check(d, "process start")
        #expect(start?.level == .warn)
        #expect(start?.message.contains("watchdog") == true)
        #expect(start?.message.contains("did NOT shut down cleanly") == true)
    }

    @Test func repeatedFreshKeyInvalidKeyAsksForReport() {
        let d = AppAttestDeepDiagnosis.evaluate(
            status(history: AppAttestKeyHistory(generationsLast24h: 5, keyAgeSeconds: 30),
                   failure: AppAttestLastAppleFailure(observedAt: 990, action: .attestation, result: "apple_invalid_key",
                                                      nativeErrorChain: [.init(domain: .devicecheck, code: 3)])),
            pushHistory: nil, now: 1_000)
        #expect(check(d, "key history")?.level == .warn)
        #expect(check(d, "key history")?.fix?.contains("darkbloom report") == true)
        #expect(check(d, "last apple failure")?.message.contains("devicecheck 3") == true)
    }


    @Test func cryptoTokenKitKeyLossIsExplained() {
        let d = AppAttestDeepDiagnosis.evaluate(
            status(failure: AppAttestLastAppleFailure(observedAt: 900, action: .assertion, result: "apple_error", nativeErrorChain: [
                .init(domain: .devicecheck, code: 0), .init(domain: .cryptotokenkit, code: -3), .init(domain: .aks, code: -536_362_989),
            ])), pushHistory: nil, now: 1_000)
        let failure = check(d, "last apple failure")
        #expect(failure?.message.contains("aks -536362989") == true)
        #expect(failure?.message.contains("Secure Enclave refused") == true)
    }

    @Test func knownEnvironmentMismatchCannotPassSigning() {
        for environment in [AppAttestPreflight.EnvironmentEntitlement.production, .development] {
            let preflight = AppAttestPreflight(optInEntitlement: true, environmentEntitlement: environment,
                                              profilePresent: true, profileExpired: false, bundlePathClass: .userInstall)
            var snapshot = status(process: .init(preflight: preflight))
            snapshot.availabilityReason = .environmentMismatch
            let result = check(AppAttestDeepDiagnosis.evaluate(snapshot, pushHistory: nil, now: 1_000), "app signing")
            #expect(result?.level == .fail)
            #expect(result?.message.contains("does not match") == true)
        }
        #expect(AppAttestDeepDiagnosis.preflightDiagnostic(.init(optInEntitlement: true, environmentEntitlement: .absent,
            profilePresent: true, profileExpired: false, bundlePathClass: .userInstall))?.level == .pass)
    }

    @Test func pushHistoryDistinguishesNoTokenNoDeliveryAndUnanswered() {
        let now = 100_000.0
        let noToken = AppAttestDeepDiagnosis.pushDiagnostic(APNsPushHistory(deviceTokenPresent: false), now: now)
        #expect(noToken?.message.contains("APNs registration failed") == true)
        let none = AppAttestDeepDiagnosis.pushDiagnostic(APNsPushHistory(deviceTokenPresent: true), now: now)
        #expect(none?.level == .info)
        #expect(none?.fix == nil)
        #expect(none?.message.contains("indeterminate") == true)
        let old = AppAttestDeepDiagnosis.pushDiagnostic(APNsPushHistory(receivedAt: [1], repliedAt: [2], deviceTokenPresent: true), now: now)
        #expect(old?.level == .info && old?.fix == nil)
        let unanswered = AppAttestDeepDiagnosis.pushDiagnostic(
            APNsPushHistory(receivedAt: [now - 60], repliedAt: [now - 3_600], deviceTokenPresent: true), now: now)
        #expect(unanswered?.level == .warn)
        let answered = AppAttestDeepDiagnosis.pushDiagnostic(
            APNsPushHistory(receivedAt: [now - 60], repliedAt: [now - 59], deviceTokenPresent: true), now: now)
        #expect(answered?.level == .pass)
        #expect(AppAttestDeepDiagnosis.pushDiagnostic(nil, now: now) == nil)
    }
}
