/// SecurityHardening -- runtime protections for the provider process.
///
/// Implements the provider's runtime security hardening in pure Swift with
/// Darwin C bridging:
///
///   - PT_DENY_ATTACH: prevents debugger attachment (lldb, dtrace)
///   - SIP verification: checks System Integrity Protection is enabled
///   - RDMA check: reports Thunderbolt RDMA status for coordinator policy
///   - Binary self-hash: SHA-256 of the running executable
///   - Core dump disabling: RLIMIT_CORE set to 0
///   - Environment scrubbing: removes dangerous env vars (DYLD_*, etc.)
///   - Anti-debug detection: P_TRACED flag, sysctl kern.proc
///   - Secure Boot self-report for coordinator MDM cross-check
///   - Hardened Runtime check: codesign entitlement verification
///   - Bundle signature verification: validates .app code signature
///   - MDM enrollment detection: MicroMDM profile checks
///
/// These protections work with macOS Hardened Runtime (applied at code signing
/// time) and SIP to prevent the provider (machine owner) from inspecting
/// inference data in flight.

import CryptoKit
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "security")

// MARK: - Errors

public enum SecurityError: Error, CustomStringConvertible, Sendable {
    case ptDenyAttachFailed(String)
    case coreDumpDisableFailed(String)
    case rdmaEnabled
    case debuggerDetected
    case bundleSignatureInvalid(String)

    public var description: String {
        switch self {
        case .ptDenyAttachFailed(let reason):
            return "PT_DENY_ATTACH failed: \(reason)"
        case .coreDumpDisableFailed(let reason):
            return "Failed to disable core dumps: \(reason)"
        case .rdmaEnabled:
            return "RDMA policy rejected this runtime"
        case .debuggerDetected:
            return "Debugger attachment detected (P_TRACED)"
        case .bundleSignatureInvalid(let reason):
            return "App bundle signature invalid: \(reason)"
        }
    }
}

// MARK: - SIP Check

/// Signed SIP self-report. Preserve the existing wire meaning (enabled includes
/// Custom Configuration) while local posture warns unless protection is full;
/// coordinator MDM remains authoritative for trust.
public func checkSIPEnabled(runner: SecurityCommandRunner = .live) -> Bool {
    let status = SIPStatusChecker(runner: runner).status()
    switch status {
    case .enabled:
        logger.info("SIP check: System Integrity Protection is fully enabled")
    case .enabledWithCustomConfiguration:
        logger.error("SIP check: System Integrity Protection is only partially enabled (Custom Configuration)")
    case .disabled:
        logger.error("SIP check: System Integrity Protection is DISABLED")
    case .unavailable(let reason):
        logger.error("SIP check: could not determine SIP status: \(reason)")
    case .unrecognized:
        logger.error("SIP check: could not interpret csrutil output")
    }
    return status.reportsEnabled
}

// MARK: - RDMA Check

/// Check if RDMA (Remote Direct Memory Access) is disabled.
///
/// RDMA over Thunderbolt exposes IOMMU-mapped memory regions registered by
/// the RDMA runtime. It is allowed for RDMA-aware provider modes, but must be
/// reported truthfully so the coordinator can apply the correct routing policy.
/// Enabling RDMA requires booting into Recovery OS and running
/// `rdma_ctl enable`.
///
/// Returns true if RDMA is disabled (safe) or if rdma_ctl is not
/// available (older macOS without RDMA support).
public func checkRDMADisabled() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/rdma_ctl")
    process.arguments = ["status"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        // rdma_ctl not found means RDMA is not supported on this Mac
        // (pre-macOS 26.2 or hardware without Thunderbolt 5 RDMA support).
        logger.debug("RDMA check: rdma_ctl not available, assuming safe")
        return true
    }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    let disabled = output.trimmingCharacters(in: .whitespacesAndNewlines) == "disabled"

    if disabled {
        logger.debug("RDMA check: RDMA is disabled")
    } else {
        logger.debug("RDMA check: RDMA is enabled")
    }
    return disabled
}

// MARK: - Secure Boot Check

/// Provider Secure Boot self-report retained for wire compatibility. macOS has
/// no stable unprivileged local API for this policy; the coordinator verifies
/// Apple's typed MDM SecurityInfo before granting hardware trust.
public func checkSecureBootEnabled(runner: SecurityCommandRunner = .live) -> Bool {
    checkAuthenticatedRootEnabled(runner: runner)
}

// MARK: - Authenticated Root Volume

/// Signed Authenticated Root Volume self-report. `csrutil authenticated-root`
/// is primary and `diskutil info /` is the fallback; only a positive enabled or
/// sealed result returns true. "Broken" remains unconfirmed rather than being
/// treated as healthy.
public func checkAuthenticatedRootEnabled(runner: SecurityCommandRunner = .live) -> Bool {
    // csrutil primary: check "disabled" before "enabled" to prefer the explicit
    // downgrade reading and guard against any substring overlap.
    if let result = try? runner.run("/usr/bin/csrutil", ["authenticated-root", "status"]),
       result.terminationStatus == 0 {
        let normalized = result.stdout.lowercased()
        if normalized.contains("disabled") { return false }
        if normalized.contains("enabled") { return true }
    }

    // diskutil fallback for older macOS where csrutil prompts interactively.
    if let result = try? runner.run("/usr/sbin/diskutil", ["info", "/"]),
       result.terminationStatus == 0 {
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Sealed:") else { continue }
            // "Sealed: Yes" ⇒ sealed; "No" or an ambiguous "Broken" (macOS 26
            // mislabels a healthy seal) ⇒ not positively confirmed.
            return trimmed.localizedCaseInsensitiveContains("Yes")
        }
    }

    return false
}

// MARK: - Hardened Runtime Check

/// Check if this binary is running with Hardened Runtime enabled.
///
/// Hardened Runtime prevents code injection, DYLD environment variables,
/// and debugging (unless the get-task-allow entitlement is present).
/// It is applied at code signing time and enforced by the kernel.
///
/// Verifies using `codesign --display --verbose` on the current executable.
public func checkHardenedRuntimeEnabled() -> Bool {
    guard let exePath = executablePath() else { return false }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--display", "--verbose", exePath]

    // codesign writes to stderr, not stdout
    let errPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        logger.warning("Hardened Runtime check: failed to run codesign: \(error)")
        return false
    }
    process.waitUntilExit()

    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    // Look for "flags=0x10000(runtime)" which indicates hardened runtime
    let hasRuntime = output.contains("runtime")
    if hasRuntime {
        logger.info("Hardened Runtime is enabled")
    } else {
        logger.warning("Hardened Runtime is NOT enabled")
    }
    return hasRuntime
}

// MARK: - Bundle Signature Verification

/// Verify the app bundle's code signature using macOS codesign.
///
/// If the binary is running from within a .app bundle, verify the
/// bundle's code signature is valid. A modified bundle (any file changed)
/// will fail this check.
///
/// Returns nil if the signature is valid or we're not in a bundle.
/// Returns an error message string if the signature is invalid.
public func verifyBundleSignature() throws {
    guard let exePath = executablePath() else { return }

    // Walk up to find the .app bundle
    var url = URL(fileURLWithPath: exePath)
    var appPath: String?

    while url.path != "/" {
        if url.pathExtension == "app" {
            appPath = url.path
            break
        }
        url = url.deletingLastPathComponent()
    }

    guard let bundlePath = appPath else {
        logger.debug("Not running from .app bundle, skipping bundle signature check")
        return
    }

    logger.info("Verifying app bundle signature: \(bundlePath, privacy: .public)")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--verify", "--verbose=0", bundlePath]

    let errPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        logger.warning("Could not verify bundle signature: \(error)")
        return // Don't fail if codesign isn't available
    }
    process.waitUntilExit()

    if process.terminationStatus == 0 {
        logger.info("App bundle signature valid")
    } else {
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? "unknown error"
        throw SecurityError.bundleSignatureInvalid(stderr)
    }
}

// MARK: - Secure Memory Zeroing

/// Zero out a byte buffer to prevent sensitive data from persisting in memory.
///
/// Uses `memset_s` which is guaranteed not to be optimized away by the
/// compiler (unlike a regular memset or loop). This is the C11 standard
/// mechanism for secure memory clearing.
public func secureZero(_ buffer: UnsafeMutableRawBufferPointer) {
    guard !buffer.isEmpty, let ptr = buffer.baseAddress else { return }
    // memset_s is guaranteed not to be optimized away (C11 Annex K / macOS).
    _ = memset_s(ptr, buffer.count, 0, buffer.count)
}

/// Zero a Data value in place and replace it with empty data.
///
/// After this call the original bytes are overwritten. The Data value
/// is then replaced with an empty Data to drop the buffer.
public func secureZeroData(_ data: inout Data) {
    data.withUnsafeMutableBytes { buffer in
        guard !buffer.isEmpty, let ptr = buffer.baseAddress else { return }
        _ = memset_s(ptr, buffer.count, 0, buffer.count)
    }
    data = Data()
}

// MARK: - Security Posture Verification

/// Result of a full security posture check.
public struct SecurityPosture: Sendable {
    public let sipEnabled: Bool
    public let rdmaDisabled: Bool
    public let secureBootEnabled: Bool
    public let authenticatedRootEnabled: Bool
    public let hardenedRuntimeEnabled: Bool
    public let antiDebugEnabled: Bool
    public let coreDumpsDisabled: Bool
    public let envScrubbed: Bool
    public let mdmEnrolled: Bool
    public let bundleSignatureValid: Bool
    public let binaryHash: String?

}

/// Collect startup posture. Failures are reported to the coordinator, which
/// owns the routing trust decision; local startup remains warning-only.
public func collectSecurityPosture() -> SecurityPosture {
    let sipEnabled = checkSIPEnabled()
    if !sipEnabled {
        logger.warning("SIP is not fully enabled; coordinator trust verification will decide routing")
    }

    let rdmaDisabled = checkRDMADisabled()

    // Anti-debug: PT_DENY_ATTACH + P_TRACED check
    var antiDebugOk = true
    do {
        try denyDebuggerAttachment()
    } catch {
        logger.warning("PT_DENY_ATTACH failed (may already be set): \(error)")
        // Not fatal on retry -- PT_DENY_ATTACH returns EPERM if already set
        antiDebugOk = !checkDebuggerAttached()
    }

    var coreDumpsOk = true
    do {
        try disableCoreDumps()
    } catch {
        logger.warning("Failed to disable core dumps: \(error)")
        coreDumpsOk = false
    }

    scrubDangerousEnvironment()

    var bundleOk = true
    do {
        try verifyBundleSignature()
    } catch {
        logger.error("Bundle signature verification failed: \(error)")
        bundleOk = false
    }

    return SecurityPosture(
        sipEnabled: sipEnabled,
        rdmaDisabled: rdmaDisabled,
        secureBootEnabled: checkSecureBootEnabled(),
        authenticatedRootEnabled: checkAuthenticatedRootEnabled(),
        hardenedRuntimeEnabled: checkHardenedRuntimeEnabled(),
        antiDebugEnabled: antiDebugOk,
        coreDumpsDisabled: coreDumpsOk,
        envScrubbed: true,
        mdmEnrolled: checkMDMEnrollment().isDarkbloom,
        bundleSignatureValid: bundleOk,
        binaryHash: selfBinaryHash()
    )
}

// MARK: - Response Attestation

/// Compute a SHA-256 hash and optional Secure Enclave signature over an
/// inference response, for coordinator verification.
///
/// The hash covers `requestId:completionTokens:responseBody`.
public func computeResponseAttestation(
    identity: (any AttestationSigner)?,
    requestId: String,
    completionTokens: UInt64,
    responseBody: String
) -> (hash: String, signature: String?) {
    let signData = "\(requestId):\(completionTokens):\(responseBody)"
    let responseHash = sha256Hex(Data(signData.utf8))

    var signature: String?
    if let identity {
        if let sigData = try? identity.sign(Data(responseHash.utf8)) {
            signature = sigData.base64EncodedString()
        }
    }

    return (responseHash, signature)
}

// MARK: - System Volume Hash

/// Get the Authenticated Root Volume snapshot hash.
///
/// This is the cryptographic hash of the sealed system volume. It proves
/// the system volume is Apple's original, unmodified volume. The hash
/// is embedded in the APFS snapshot name.
public func systemVolumeHash() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "/"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    // Extract hash from snapshot name: com.apple.os.update-<HASH>
    for line in output.components(separatedBy: "\n") {
        if line.contains("APFS Snapshot Name") {
            if let range = line.range(of: "com.apple.os.update-") {
                let hash = String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !hash.isEmpty {
                    return hash
                }
            }
        }
    }
    return nil
}
