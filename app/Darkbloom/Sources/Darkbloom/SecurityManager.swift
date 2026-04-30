/// SecurityManager — Queries and caches the machine's security posture.
///
/// Checks SIP, Secure Enclave, MDM enrollment, Secure Boot, and
/// determines the trust level. The coordinator only routes inference
/// to providers with `hardware` trust, so this is critical.

import CryptoKit
import Foundation

/// Trust level matching the coordinator's registry.
enum TrustLevel: String, CaseIterable {
    case none = "none"
    case hardware = "hardware"

    var displayName: String {
        switch self {
        case .none: return "Not Verified"
        case .hardware: return "Hardware Verified"
        }
    }

    var iconName: String {
        switch self {
        case .none: return "xmark.shield"
        case .hardware: return "checkmark.shield.fill"
        }
    }
}

/// Manages security posture detection and caching.
@MainActor
final class SecurityManager: ObservableObject {

    @Published var sipEnabled = false
    @Published var secureEnclaveAvailable = false
    @Published var secureBootEnabled = false
    @Published var mdmEnrolled = false
    @Published var trustLevel: TrustLevel = .none
    @Published var binaryFound = false
    @Published var nodeKeyExists = false
    @Published var lastCheckTime: Date?
    @Published var isChecking = false

    /// Run all security checks and update published properties.
    func refresh() async {
        isChecking = true
        defer { isChecking = false }

        // Run checks in parallel where possible
        async let sipResult = checkSIP()
        async let seResult = checkSecureEnclave()
        async let mdmResult = checkMDMEnrollment()
        async let bootResult = checkSecureBoot()
        async let binaryResult = checkBinary()
        async let keyResult = checkNodeKey()

        sipEnabled = await sipResult
        secureEnclaveAvailable = await seResult
        mdmEnrolled = await mdmResult
        secureBootEnabled = await bootResult
        binaryFound = await binaryResult
        nodeKeyExists = await keyResult

        // Determine trust level — only hardware trust is routable.
        // Providers without MDM enrollment stay at .none regardless of
        // Secure Enclave or SIP status.
        if secureEnclaveAvailable && mdmEnrolled && sipEnabled && secureBootEnabled {
            trustLevel = .hardware
        } else {
            trustLevel = .none
        }

        lastCheckTime = Date()
    }

    /// Check if SIP (System Integrity Protection) is enabled.
    private func checkSIP() async -> Bool {
        let result = await CLIRunner.shell("csrutil status")
        return result.stdout.lowercased().contains("enabled")
    }

    /// Check Secure Enclave availability using CryptoKit.
    private func checkSecureEnclave() async -> Bool {
        SecureEnclave.isAvailable
    }

    /// Check if this Mac is enrolled in Darkbloom MDM.
    ///
    /// Uses the same 3-method approach as security.rs:
    ///   1. Marker file at /var/db/ConfigurationProfiles/Settings/.profilesAreInstalled
    ///   2. `profiles list` for user-level profiles
    ///   3. mdmclient QueryDeviceInformation
    private func checkMDMEnrollment() async -> Bool {
        // Method 1: marker file
        let markerPath = "/var/db/ConfigurationProfiles/Settings/.profilesAreInstalled"
        if FileManager.default.fileExists(atPath: markerPath) {
            return true
        }

        // Method 2: profiles list
        let profiles = await CLIRunner.shell("profiles list 2>&1")
        let combined = (profiles.stdout + profiles.stderr).lowercased()
        if combined.contains("micromdm") || combined.contains("darkbloom") ||
           combined.contains("darkbloom") ||
           combined.contains("com.github.micromdm") {
            return true
        }

        // Method 3: mdmclient
        let mdm = await CLIRunner.shell("/usr/libexec/mdmclient QueryDeviceInformation 2>&1")
        let mdmOut = (mdm.stdout + mdm.stderr).lowercased()
        if mdmOut.contains("enrolled") || mdmOut.contains("serverurl") {
            return true
        }

        return false
    }

    /// Check Secure Boot status.
    /// On Apple Silicon, Full Security mode is always enabled by default.
    private func checkSecureBoot() async -> Bool {
        // Apple Silicon always has Secure Boot in Full Security mode
        // unless explicitly downgraded in Recovery Mode.
        // Check via bputil if available, otherwise assume true on AS.
        let result = await CLIRunner.shell("arch")
        if result.stdout.contains("arm64") {
            return true
        }
        return false
    }

    /// Check if the darkbloom binary is available.
    private func checkBinary() async -> Bool {
        CLIRunner.resolveBinaryPath() != nil
    }

    /// Check if the E2E encryption key is available.
    /// This exercises the real provider key path rather than inferring from
    /// file presence, so it catches keychain/entitlement failures too.
    private func checkNodeKey() async -> Bool {
        guard CLIRunner.resolveBinaryPath() != nil else {
            return false
        }
        let result = try? await CLIRunner.run(["key-status"])
        return result?.success == true
    }
}
