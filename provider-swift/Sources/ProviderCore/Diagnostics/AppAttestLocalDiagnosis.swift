import Foundation
import ProviderAppAttest

/// "What does this Mac's own App Attest state look like?" — rendered by
/// `darkbloom doctor` from the daemon's last local observation
/// (`DaemonState.appAttest`). Local diagnostics only: the coordinator's
/// serving authorization, shown in the trust section, stays authoritative.
public enum AppAttestLocalDiagnosis {
    static let isSupportedFalseFix =
        "Run the provider inside the logged-in GUI session: log in at the console (or via Screen Sharing), "
        + "then `darkbloom restart`; enable automatic login so the session exists after reboots. Also confirm "
        + "SIP is enabled (`csrutil status`) and Startup Security Utility in Recovery is set to Full Security."

    /// App Attest verdicts require macOS 27; persisted APNs history is useful
    /// on every supported OS, including without an App Attest observation.
    /// `pushHistory` is the local `apns-push-history.json`, read by the CLI.
    public static func evaluate(_ status: AppAttestLocalStatus?, daemonRunning: Bool,
                                macOSMajorVersion: Int, now: Double, pushHistory: APNsPushHistory? = nil) -> [Diagnostic] {
        let pushes = AppAttestDeepDiagnosis.pushDiagnostic(pushHistory, now: now).map { [$0] } ?? []
        guard ProviderOnboardingPolicy.usesAppAttest(macOSMajorVersion: macOSMajorVersion) else { return pushes }
        guard daemonRunning, let status else {
            return pushes + [Diagnostic(section: .appAttest, name: "app attest key", level: .warn,
                               message: daemonRunning
                                   ? "the provider has not reported its local App Attest state yet (it does so on each coordinator App Attest exchange)."
                                   : "the provider daemon isn't running, so its local App Attest state is unavailable.",
                               fix: daemonRunning ? "wait a minute and re-run `darkbloom doctor`." : "run `darkbloom start`, then `darkbloom doctor`.")]
        }
        var out = pushes + [launchSession(status.launchSession)]
        if let reason = status.availabilityReason {
            out.append(reason == .isSupportedFalse
                ? Diagnostic(section: .appAttest, name: "app attest support", level: .fail,
                             message: "Apple reports App Attest as unsupported for this provider process (`is_supported_false`)"
                                 + (status.launchSession == .background ? ", which runs outside the logged-in GUI session." : "."),
                             fix: isSupportedFalseFix)
                : Diagnostic(section: .appAttest, name: "app attest support", level: .fail,
                             message: "App Attest is unavailable to this provider process (`\(reason.rawValue)`).",
                             fix: "run the signed Darkbloom.app release on macOS 27 or later (`darkbloom update`), then `darkbloom restart`."))
        }
        if let stalled = status.operationStalledSeconds {
            out.append(Diagnostic(section: .appAttest, name: "apple operation", level: .warn,
                                  message: "an Apple DeviceCheck call has not answered for \(duration(Double(stalled))); App Attest reports busy until the provider restarts. The provider restarts itself once no inference is active (at most once every \(Int(AppAttestStallRestartPolicy.minimumInterval / 3600)) h).",
                                  fix: "if it persists, run `darkbloom restart`."))
        }
        // Unavailable App Attest never reads Keychain, so there is no key state.
        if status.availabilityReason == nil { out.append(keyDiagnostic(status.key, now: now)) }
        out.append(contentsOf: AppAttestDeepDiagnosis.evaluate(status, pushHistory: nil, now: now))
        return out
    }

    private static func launchSession(_ session: AppAttestLaunchSession) -> Diagnostic {
        switch session {
        case .gui:
            return Diagnostic(section: .appAttest, name: "launch session", level: .pass,
                              message: "the provider runs in a logged-in GUI session.")
        case .background:
            return Diagnostic(section: .appAttest, name: "launch session", level: .warn,
                              message: "the provider runs outside the logged-in GUI session; App Attest may report unsupported there.",
                              fix: "log in at the console and run `darkbloom restart` so launchd starts it inside the GUI session.")
        case .unknown:
            return Diagnostic(section: .appAttest, name: "launch session", level: .warn,
                              message: "the provider could not determine its security session.")
        }
    }

    private static func keyDiagnostic(_ key: AppAttestKeyState?, now: Double) -> Diagnostic {
        guard let key else {
            return Diagnostic(section: .appAttest, name: "app attest key", level: .warn,
                              message: "the provider could not read its App Attest key record from the Keychain.",
                              fix: "unlock the login keychain, then `darkbloom restart`.")
        }
        if key.recordPresent {
            return Diagnostic(section: .appAttest, name: "app attest key", level: .pass,
                              message: key.attested
                                  ? "a key is stored and was enrolled with Apple on this Mac. The coordinator replaces it if Apple stops signing with it."
                                  : "a key is stored and awaits Apple enrollment by the coordinator.")
        }
        if let until = key.generationBlockedUntil, until > now {
            return Diagnostic(section: .appAttest, name: "app attest key", level: .warn,
                              message: "no usable key; a replacement can be generated in \(duration(until - now)) (Apple key-generation cooldown).",
                              fix: "no action needed; the coordinator retries automatically. Do not delete Keychain items.")
        }
        return Diagnostic(section: .appAttest, name: "app attest key", level: .pass,
                          message: "no key yet; one is generated on the next coordinator App Attest exchange.")
    }

    private static func duration(_ seconds: Double) -> String {
        DurationFormatting.compact(seconds, spaced: false, elideZeroMinutesInHourRange: false)
    }
}
