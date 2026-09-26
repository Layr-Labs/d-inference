import Foundation
import ProviderAppAttest

/// Human-readable verdicts over the deep App Attest diagnostics the provider
/// sent on its last `ready` (process start, boot security, preflight, key and
/// APNs push history, last native Apple error). Pure; rendered by
/// `darkbloom doctor` in the APP ATTEST section.
public enum AppAttestDeepDiagnosis {
    static let reportAdvice = "run `darkbloom report` from an administrator account (or `sudo darkbloom report` if this account is allowed to use sudo) so support receives key_history and devicecheckd evidence."

    public static func evaluate(_ status: AppAttestLocalStatus, pushHistory: APNsPushHistory?, now: Double) -> [Diagnostic] {
        var out: [Diagnostic] = []
        if let process = status.process {
            out.append(processStart(process))
            if let session = sessionMismatch(process, launchSession: status.launchSession) { out.append(session) }
            if let boot = bootSecurity(process) { out.append(boot) }
            if let preflight = process.preflight.flatMap(preflightDiagnostic) { out.append(preflight) }
        }
        if let history = status.keyHistory { out.append(keyHistory(history, lastFailure: status.lastAppleFailure)) }
        if let failure = status.lastAppleFailure { out.append(lastFailure(failure, now: now)) }
        if let push = pushDiagnostic(pushHistory, now: now) { out.append(push) }
        return out
    }

    // MARK: - Process start

    static func processStart(_ p: AppAttestProcessDiagnostics) -> Diagnostic {
        let reason: String
        switch p.startReason {
        case .launchd?: reason = "started by launchd (login, boot or kickstart)"
        case .watchdog?: reason = "restarted by the Darkbloom watchdog after an outage"
        case .update?: reason = "started after a provider update"
        case .stallRestart?: reason = "restarted automatically to release a stalled Apple DeviceCheck call"
        case .manual?: reason = "started manually (CLI or foreground)"
        case .unknown?, nil: reason = "start reason unknown"
        }
        let exit: String
        switch p.previousExit {
        case .clean?: exit = "the previous provider process shut down cleanly"
        case .unclean?: exit = "the previous provider process did NOT shut down cleanly (crash, force-kill, power loss or reboot without a drain)"
        case .unknown?, nil: exit = "how the previous provider process ended is unknown"
        }
        return Diagnostic(section: .appAttest, name: "process start", level: p.previousExit == .unclean ? .warn : .pass,
                          message: "\(reason); \(exit).",
                          fix: p.previousExit == .unclean
                              ? "if App Attest broke right after this restart, " + reportAdvice : nil)
    }

    // MARK: - GUI session

    static func sessionMismatch(_ p: AppAttestProcessDiagnostics, launchSession: AppAttestLaunchSession) -> Diagnostic? {
        guard launchSession == .background else { return nil }
        if p.consoleUserActive == true {
            return Diagnostic(section: .appAttest, name: "gui session", level: .warn,
                              message: "a user is logged in at the console, but the provider was launched outside that GUI session (e.g. over SSH or by a system daemon).",
                              fix: "run `darkbloom restart` from the logged-in desktop session (Terminal on the Mac, or Screen Sharing) so launchd starts it inside the GUI session.")
        }
        if p.consoleUserActive == false {
            return Diagnostic(section: .appAttest, name: "gui session", level: .warn,
                              message: "no user is logged in at the console, so no GUI session exists for the provider.",
                              fix: "log in at the Mac's login window (or via Screen Sharing), enable automatic login, then `darkbloom restart`.")
        }
        return nil
    }

    // MARK: - Boot security

    static func bootSecurity(_ p: AppAttestProcessDiagnostics) -> Diagnostic? {
        guard p.sipEnabled != nil || p.authenticatedRoot != nil else { return nil }
        var problems: [String] = []
        if p.sipEnabled == false { problems.append("System Integrity Protection is not fully enabled") }
        if p.authenticatedRoot == false { problems.append("Authenticated Root is not confirmed enabled") }
        guard !problems.isEmpty else {
            let parts = [p.sipEnabled == true ? "SIP enabled" : nil, p.authenticatedRoot == true ? "authenticated root enabled" : nil]
            return Diagnostic(section: .appAttest, name: "boot security", level: .pass,
                              message: parts.compactMap { $0 }.joined(separator: ", ") + ".")
        }
        return Diagnostic(section: .appAttest, name: "boot security", level: .fail,
                          message: problems.joined(separator: "; ") + ". Apple requires Full Security for App Attest.",
                          fix: "boot into Recovery, run `csrutil enable` and `csrutil authenticated-root enable`, set Startup Security Utility to Full Security, then restart.")
    }

    // MARK: - Preflight

    static func preflightDiagnostic(_ p: AppAttestPreflight) -> Diagnostic? {
        var problems: [String] = []
        if p.optInEntitlement == false { problems.append("the App Attest opt-in entitlement is missing") }
        if p.environmentEntitlement == .invalid { problems.append("the App Attest environment entitlement is invalid") }
        if p.profilePresent == false { problems.append("the embedded provisioning profile is missing") }
        if p.profileExpired == true { problems.append("the embedded provisioning profile has expired") }
        if !problems.isEmpty {
            return Diagnostic(section: .appAttest, name: "app signing", level: .fail,
                              message: problems.joined(separator: "; ") + ".",
                              fix: "reinstall the signed release: `curl -fsSL https://api.darkbloom.dev/install.sh | bash`, then `darkbloom restart`.")
        }
        guard p.optInEntitlement != nil || p.profilePresent != nil else { return nil }
        let location: String
        switch p.bundlePathClass {
        case .userInstall?: location = "installed in ~/.darkbloom"
        case .applications?: location = "installed in Applications"
        case .other?: location = "running from an unusual location"
        case nil: location = "install location unknown"
        }
        return Diagnostic(section: .appAttest, name: "app signing", level: p.bundlePathClass == .other ? .warn : .pass,
                          message: "entitlements and provisioning profile present; \(location).",
                          fix: p.bundlePathClass == .other ? "run the installed release from ~/.darkbloom (`darkbloom update`)." : nil)
    }

    // MARK: - Key history

    static func keyHistory(_ h: AppAttestKeyHistory, lastFailure: AppAttestLastAppleFailure?) -> Diagnostic {
        var facts: [String] = []
        if let n = h.generationsLast24h { facts.append("\(n) key generation(s) in 24 h") }
        if let age = h.keyAgeSeconds { facts.append("current key \(duration(age)) old") }
        if let v = h.createdAppVersion { facts.append("created by v\(v)") }
        if let same = h.createdBootMatches { facts.append(same ? "created this boot" : "created in an earlier boot") }
        if let age = h.lastSuccessAgeSeconds { facts.append("last Apple success \(duration(age)) ago") }
        if let n = h.consecutiveAssertionFailures, n > 0 { facts.append("\(n) consecutive assertion failure(s)") }
        let freshKeyInvalid = (h.generationsLast24h ?? 0) >= 3 && lastFailure?.result == "apple_invalid_key"
            && lastFailure?.action == .attestation
        let dying = (h.consecutiveAssertionFailures ?? 0) >= 2
        if freshKeyInvalid {
            return Diagnostic(section: .appAttest, name: "key history", level: .warn,
                              message: facts.joined(separator: "; ") + ". Apple rejects even brand-new keys (invalidKey on first attestation).",
                              fix: reportAdvice)
        }
        if dying {
            return Diagnostic(section: .appAttest, name: "key history", level: .warn,
                              message: facts.joined(separator: "; ") + ". Apple can no longer sign with this key; the coordinator will rotate it.",
                              fix: "no action needed for rotation; if it recurs after restarts, " + reportAdvice)
        }
        return Diagnostic(section: .appAttest, name: "key history", level: .pass,
                          message: facts.isEmpty ? "no key history yet." : facts.joined(separator: "; ") + ".")
    }

    static func lastFailure(_ f: AppAttestLastAppleFailure, now: Double) -> Diagnostic {
        let chain = f.nativeErrorChain.map { entries in
            " Native error chain: " + entries.map { "\($0.domain.rawValue) \($0.code)" }.joined(separator: " → ") + "."
        } ?? ""
        let keyLoss = f.nativeErrorChain?.contains { $0.domain == .cryptotokenkit && $0.code == -3 } == true
        return Diagnostic(section: .appAttest, name: "last apple failure", level: .warn,
                          message: "\(f.action.rawValue) failed \(duration(max(0, Int(now - f.observedAt)))) ago with `\(f.result)`.\(chain)"
                              + (keyLoss ? " CryptoTokenKit -3 means the Secure Enclave refused to sign with the stored key." : ""),
                          fix: keyLoss ? "the coordinator rotates a dead key automatically; " + reportAdvice : nil)
    }

    // MARK: - APNs pushes

    static func pushDiagnostic(_ history: APNsPushHistory?, now: Double) -> Diagnostic? {
        guard let history else { return nil }
        let summary = history.summary(deviceTokenPresent: history.deviceTokenPresent, now: Date(timeIntervalSince1970: now))
        if history.deviceTokenPresent == false {
            return Diagnostic(section: .appAttest, name: "apns pushes", level: .warn,
                              message: "the provider has no APNs device token, so the coordinator cannot push code-identity checks (APNs registration failed).",
                              fix: "keep the provider running inside the logged-in GUI session with network access, then `darkbloom restart`.")
        }
        let received = summary.pushesReceivedLast24h ?? 0
        let lastReply = summary.lastReplySentAgeSeconds.map { "last reply \(duration($0)) ago" } ?? "no reply recorded"
        let lastPush = summary.lastPushReceivedAgeSeconds.map { "last push \(duration($0)) ago" } ?? "no push ever received"
        if received == 0 {
            return Diagnostic(section: .appAttest, name: "apns pushes", level: .warn,
                              message: "no code-identity push received in 24 h (\(lastPush); \(lastReply)). If the coordinator reports unanswered pushes, APNs is not delivering them to this Mac.",
                              fix: "keep the Mac awake and online (`sudo pmset -a sleep 0`), stay logged in, and check that outbound TCP 5223 to Apple is not blocked.")
        }
        let repliedAfter = (summary.lastReplySentAgeSeconds ?? Int.max) <= (summary.lastPushReceivedAgeSeconds ?? Int.max)
        return Diagnostic(section: .appAttest, name: "apns pushes", level: repliedAfter ? .pass : .warn,
                          message: "\(received) code-identity push(es) received in 24 h (\(lastPush); \(lastReply)).",
                          fix: repliedAfter ? nil : "the latest push was received but not answered; `darkbloom restart` and re-run `darkbloom doctor`.")
    }

    private static func duration(_ seconds: Int) -> String {
        DurationFormatting.compact(Double(seconds), spaced: false, elideZeroMinutesInHourRange: false)
    }
}
