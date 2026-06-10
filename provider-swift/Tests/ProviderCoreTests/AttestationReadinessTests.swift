import Foundation
import Testing
@testable import ProviderCore

// MARK: - AttestationReadiness (pure verdict logic)

/// Pulls the diagnostic for a given check name out of the evaluated set.
private func check(_ diags: [Diagnostic], _ name: String) -> Diagnostic? {
    diags.first { $0.name == name }
}

@Test func attestationReadinessNoConsoleUserFails() {
    // The headline case: nobody logged in at the console → cannot obtain an
    // APNs token → cannot attest. Must FAIL.
    let d = AttestationReadiness.evaluate(
        consoleUser: nil, autoLoginUser: "provider", autoLogoutDelaySeconds: 0)
    let session = check(d, "console session")
    #expect(session?.level == .fail)
    #expect(session?.fix != nil)
    // Every check still belongs to the dedicated readiness section.
    #expect(d.allSatisfy { $0.section == .attestationReadiness })
}

@Test func attestationReadinessLoginWindowPlaceholderFails() {
    // SCDynamicStoreCopyConsoleUser returns "loginwindow" while at the login
    // window — that is NOT a real Aqua session.
    for placeholder in ["loginwindow", "root", "", "  ", "_mbsetupuser"] {
        let d = AttestationReadiness.evaluate(
            consoleUser: placeholder, autoLoginUser: "provider", autoLogoutDelaySeconds: 0)
        #expect(check(d, "console session")?.level == .fail,
                "console user \"\(placeholder)\" must be treated as no session")
    }
}

@Test func attestationReadinessAllGoodPasses() {
    // Console user present + auto-login set + auto-logout disabled → all OK.
    let d = AttestationReadiness.evaluate(
        consoleUser: "provider", autoLoginUser: "provider", autoLogoutDelaySeconds: 0)
    #expect(check(d, "console session")?.level == .pass)
    #expect(check(d, "automatic login")?.level == .pass)
    #expect(check(d, "auto-logout on idle")?.level == .pass)
    // The critical and reboot-recovery checks all pass — no failures.
    #expect(!d.contains { $0.level == .fail })
    // The console user is surfaced in the message for the operator.
    #expect(check(d, "console session")?.message.contains("provider") == true)
}

@Test func attestationReadinessAbsentAutoLogoutTreatedAsDisabled() {
    // nil AutoLogOutDelay (the common case — setting never touched) == disabled.
    let d = AttestationReadiness.evaluate(
        consoleUser: "provider", autoLoginUser: "provider", autoLogoutDelaySeconds: nil)
    #expect(check(d, "auto-logout on idle")?.level == .pass)
}

@Test func attestationReadinessAutoLogoutEnabledFails() {
    // AutoLogOutDelay > 0 → the session is ended after idle, killing the GUI
    // LaunchAgent and the provider → FAIL.
    let d = AttestationReadiness.evaluate(
        consoleUser: "provider", autoLoginUser: "provider", autoLogoutDelaySeconds: 600)
    let logout = check(d, "auto-logout on idle")
    #expect(logout?.level == .fail)
    #expect(logout?.message.contains("10 min") == true) // 600s → 10 min
    #expect(logout?.fix != nil)
}

@Test func attestationReadinessNoAutoLoginWarns() {
    // Without auto-login the box can't self-recover a session after reboot →
    // WARN (not FAIL: a currently-logged-in box still works until it reboots).
    let d = AttestationReadiness.evaluate(
        consoleUser: "provider", autoLoginUser: nil, autoLogoutDelaySeconds: 0)
    #expect(check(d, "automatic login")?.level == .warn)
    #expect(check(d, "automatic login")?.fix != nil)

    // Empty-string autoLoginUser is the same as unset.
    let d2 = AttestationReadiness.evaluate(
        consoleUser: "provider", autoLoginUser: "   ", autoLogoutDelaySeconds: 0)
    #expect(check(d2, "automatic login")?.level == .warn)
}

@Test func attestationReadinessSleepPreventionIsInformational() {
    // Sleep prevention is low-priority/informational and never FAILs.
    let prevented = AttestationReadiness.evaluate(
        consoleUser: "u", autoLoginUser: "u", autoLogoutDelaySeconds: 0, sleepPrevented: true)
    #expect(check(prevented, "sleep prevention")?.level == .pass)

    let notPrevented = AttestationReadiness.evaluate(
        consoleUser: "u", autoLoginUser: "u", autoLogoutDelaySeconds: 0, sleepPrevented: false)
    #expect(check(notPrevented, "sleep prevention")?.level == .warn)

    let unknown = AttestationReadiness.evaluate(
        consoleUser: "u", autoLoginUser: "u", autoLogoutDelaySeconds: 0, sleepPrevented: nil)
    #expect(check(unknown, "sleep prevention")?.level == .warn)
    // Even when sleep can't be read, it is never a hard failure.
    #expect(check(unknown, "sleep prevention")?.level != .fail)
}

@Test func attestationReadinessInputsConvenienceMatchesDirect() {
    let inputs = AttestationReadiness.Inputs(
        consoleUser: "provider", autoLoginUser: "provider", autoLogoutDelaySeconds: 0)
    let viaInputs = AttestationReadiness.evaluate(inputs)
    let direct = AttestationReadiness.evaluate(
        consoleUser: "provider", autoLoginUser: "provider", autoLogoutDelaySeconds: 0)
    #expect(viaInputs == direct)
}

@Test func attestationReadinessIsRealConsoleUser() {
    #expect(AttestationReadiness.isRealConsoleUser("alice") == true)
    #expect(AttestationReadiness.isRealConsoleUser("Provider Account") == true)
    #expect(AttestationReadiness.isRealConsoleUser(nil) == false)
    #expect(AttestationReadiness.isRealConsoleUser("") == false)
    #expect(AttestationReadiness.isRealConsoleUser("loginwindow") == false)
    #expect(AttestationReadiness.isRealConsoleUser("LoginWindow") == false) // case-insensitive
    #expect(AttestationReadiness.isRealConsoleUser("root") == false)
}
