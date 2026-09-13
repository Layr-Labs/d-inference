import ProviderCore

/// Reports the running daemon's attestation-key posture without touching the
/// keychain. The daemon's coordinator trust status is the authoritative signing
/// test; Doctor must never create a second identity merely to diagnose the first.
enum SEKeySelfTest {
    /// Read-only key status, already mapped to operator advice.
    struct Result {
        let level: DiagnosticLevel
        let message: String
        let fix: String?
    }

    static func run(
        identity: DoctorAttestationIdentityResolution,
        secureEnclaveAvailable: Bool = PersistentEnclaveKey.isAvailable
    ) -> Result {
        guard secureEnclaveAvailable else {
            return Result(
                level: .warn,
                message: "no Secure Enclave on this Mac (Intel or VM) — hardware-trusted inference isn't possible here.",
                fix: "use an Apple Silicon Mac to provide hardware-trusted inference.")
        }
        guard case .available = identity else {
            return Result(
                level: .warn,
                message: "no verified active daemon attestation identity is available.",
                fix: "start or restart the provider, then re-run `darkbloom doctor`.")
        }
        return Result(
            level: .pass,
            message: "running provider reports its active Secure Enclave attestation identity.",
            fix: nil)
    }
}
