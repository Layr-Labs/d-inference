import Foundation

/// Translates the coordinator's `trust_status` reason strings into plain-language
/// explanations and concrete fixes for the operator.
///
/// The coordinator already tells a provider WHY its trust changed (via the
/// `trust_status` message's `reason` field), but that string is terse and
/// engineer-facing ("binary hash mismatch", "SE attestation verified, awaiting
/// MDM verification"). This catalog is the single source of truth that turns
/// each reason into something an operator can act on.
///
/// The reason strings here are copied verbatim from the coordinator
/// (`coordinator/api/provider.go`: `sendTrustStatus` + `handleChallengeFailure`).
/// The default arm echoes any unrecognized reason verbatim so a new coordinator
/// reason still reaches the operator instead of being hidden.
public enum TrustReasonCatalog {
    /// Maps a trust update to operator advice. `level`/`status` give context
    /// (e.g. self_signed/online means "online but not earning").
    public static func advice(
        level: String,
        status: String,
        reason: String,
        reasonCode: String? = nil
    ) -> DiagnosticAdvice {
        switch reasonCode {
        case "hardware_below_minimum":
            return DiagnosticAdvice(
                message: reason.isEmpty
                    ? "this Mac does not meet the network requirements for new providers."
                    : reason,
                fix: "use `darkbloom status` to review the reported hardware and current minimums. Join the availability list at https://console.darkbloom.dev/provider-waitlist. Existing admitted Macs remain grandfathered.")
        case "hardware_identity_required", "hardware_identity_missing":
            return DiagnosticAdvice(
                message: reason.isEmpty
                    ? "the coordinator requires an attested machine identity before onboarding."
                    : reason,
                fix: "run `darkbloom doctor`, complete enrollment, then `darkbloom restart`.")
        case "hardware_attestation_stale":
            return DiagnosticAdvice(
                message: reason.isEmpty
                    ? "the coordinator requires a fresh hardware attestation before onboarding."
                    : reason,
                fix: "update the provider, keep the Mac awake, then restart so it can complete a fresh attestation.")
        case "hardware_admission_revoked":
            return DiagnosticAdvice(
                message: reason.isEmpty
                    ? "a network operator revoked this machine's provider admission."
                    : reason,
                fix: "threshold changes cannot restore a revoked machine; contact Darkbloom support if this was unexpected.")
        case "admission_state_unavailable":
            return DiagnosticAdvice(
                message: reason.isEmpty
                    ? "the coordinator could not verify hardware admission state."
                    : reason,
                fix: "the daemon retries automatically; no hardware or enrollment change is required.")
        default:
            break
        }
        // Prefix-matched reasons (they carry a variable error suffix).
        if reason.hasPrefix("signature verification failed") {
            return DiagnosticAdvice(
                message: "the coordinator rejected your attestation signature — usually the Secure Enclave key can't sign.",
                fix: "run `darkbloom doctor` and check the Secure Enclave key; if headless/SSH, log in at the console once so the key unlocks.")
        }
        if reason.hasPrefix("status signature verification failed") {
            return DiagnosticAdvice(
                message: "the coordinator rejected your signed security-status payload (signature/canonical mismatch).",
                fix: "update to the latest build with `darkbloom update`; if it persists, review `darkbloom doctor` locally.")
        }

        switch reason {
        // ---- success / status (sendTrustStatus) ----
        // The first string is what current coordinators send; the "MDM/ACME"
        // variant is what pre-ACME-removal coordinators sent — keep matching it
        // so this build gives friendly advice against an older coordinator.
        case "SE attestation verified, awaiting MDM verification",
             "SE attestation verified, awaiting MDM/ACME upgrade":
            return DiagnosticAdvice(
                message: "verified by Secure Enclave, but NOT yet hardware-trusted. You're ONLINE but receive NO traffic until the coordinator's MDM verification completes (this network requires hardware trust).",
                fix: "run `darkbloom enroll`, then wait ~5 min for MDM verification.")
        case "MDM verification passed":
            return DiagnosticAdvice(
                message: "hardware-trusted and eligible for traffic.",
                fix: nil)
        case "MDM verification passed; awaiting Apple device identity and code attestation":
            return DiagnosticAdvice(
                message: "MDM posture passed, but first-time provider admission is still waiting for Apple device identity and official-code attestation. The machine receives no traffic yet.",
                fix: "keep the Mac awake and signed in so APNs and Apple Device Attestation can complete.")
        case "recovered after transient deroute":
            return DiagnosticAdvice(
                message: "recovered after a temporary derouting (a brief network/challenge blip).",
                fix: nil)

        // ---- challenge failures (handleChallengeFailure) → untrust ----
        case "timeout", "no response":
            return DiagnosticAdvice(
                message: "the coordinator's attestation challenge didn't get a reply in time — usually network flap, the Mac sleeping, or a wedged connection.",
                fix: "check network stability and prevent sleep; the provider auto-recovers on the next passing challenge.")
        case "nonce mismatch", "empty signature":
            return DiagnosticAdvice(
                message: "the attestation challenge response was malformed — likely a stale or broken build.",
                fix: "`darkbloom update` to the latest build.")
        case "public key mismatch":
            return DiagnosticAdvice(
                message: "your Secure Enclave key changed from what was registered (a re-minted key or a different machine identity).",
                fix: "restart the provider so it re-registers: `darkbloom stop && darkbloom start`.")
        case "SIP status not reported", "SIP disabled":
            return DiagnosticAdvice(
                message: "System Integrity Protection is off (or unreported). SIP is required for hardware trust.",
                fix: "boot into Recovery → Terminal → run `csrutil enable`, then reboot.")
        case "Secure Boot disabled":
            return DiagnosticAdvice(
                message: "Secure Boot is not set to Full Security, which is required for hardware trust.",
                fix: "boot into Recovery → Startup Security Utility → set Full Security.")
        case "RDMA status not reported — provider must update to v0.2.0+":
            return DiagnosticAdvice(
                message: "your build is too old to report required security state.",
                fix: "`darkbloom update` to a current build.")
        case "binary hash mismatch", "binary hash changed from registration attestation",
             "attested binary hash missing", "binary hash missing",
             "valid attestation required for binary hash policy":
            return DiagnosticAdvice(
                message: "the running binary doesn't match the official, attested build (or its hash couldn't be proven).",
                fix: "reinstall the official bundle and don't modify the binary: re-run the install script.")
        case "active model weight hash mismatch":
            return DiagnosticAdvice(
                message: "the model weights you're serving don't match the registered hash for that model.",
                fix: "re-download the model with `darkbloom models download <id>` so weights match the registry.")

        default:
            // Never hide an unrecognized reason — surface it verbatim.
            return DiagnosticAdvice(message: "coordinator reason: \(reason)", fix: nil)
        }
    }

    /// Convenience: the diagnostic level implied by a trust level + status.
    /// hardware/online = pass; self_signed = warn (online but not earning);
    /// untrusted/offline = fail.
    public static func level(trustLevel: String, status: String) -> DiagnosticLevel {
        if status == "untrusted" || status == "offline" || status == "onboarding_rejected" {
            return .fail
        }
        if status == "admission_pending" {
            return .warn
        }
        switch trustLevel {
        case "hardware", "mda_verified":
            return .pass
        case "self_signed":
            return .warn
        default:
            return .warn
        }
    }
}
