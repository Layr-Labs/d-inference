import Foundation
import ProviderCore

/// Runs a real Secure Enclave load+sign round-trip to prove the attestation key
/// can actually answer challenges — the #1 cause of a box being stuck untrusted
/// while looking healthy locally. Lives in the CLI (not pure ProviderCore)
/// because it touches the keychain/Security framework.
enum SEKeySelfTest {
    /// Result of the self-test, already mapped to operator advice.
    struct Result {
        let level: DiagnosticLevel
        let message: String
        let fix: String?
    }

    /// A throwaway label so the test never disturbs the production v2 key
    /// (loadOrCreate(label:) under a custom label does NO migration).
    private static let testLabel = "io.darkbloom.provider.doctor-selftest"

    static func run() -> Result {
        guard PersistentEnclaveKey.isAvailable else {
            return Result(
                level: .warn,
                message: "no Secure Enclave on this Mac (Intel or VM) — hardware-trusted inference isn't possible here.",
                fix: "use an Apple Silicon Mac to provide hardware-trusted inference.")
        }
        do {
            let key = try PersistentEnclaveKey.loadOrCreate(label: testLabel)
            _ = try key.sign(Data("darkbloom-doctor-selftest".utf8))
            // Clean up the throwaway key; ignore failure.
            try? PersistentEnclaveKey.delete(label: testLabel)
            return Result(level: .pass, message: "Secure Enclave key loads and signs correctly.", fix: nil)
        } catch let PersistentEnclaveKeyError.signingFailed(status, _) {
            let advice = OSStatusCatalog.advice(osStatus: status)
            return Result(level: .fail, message: advice.message, fix: advice.fix)
        } catch PersistentEnclaveKeyError.missingEntitlement {
            let advice = OSStatusCatalog.advice(osStatus: OSStatusCatalog.missingEntitlement)
            return Result(level: .fail, message: advice.message, fix: advice.fix)
        } catch let PersistentEnclaveKeyError.keyLookupFailed(status) {
            let advice = OSStatusCatalog.advice(osStatus: status)
            return Result(level: .warn, message: advice.message, fix: advice.fix)
        } catch {
            return Result(
                level: .fail,
                message: "Secure Enclave self-test failed: \(error.localizedDescription)",
                fix: "run `darkbloom report` and include this output.")
        }
    }
}
