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
///   - Secure Boot self-report (signed status fields)
///   - Hardened Runtime check: codesign entitlement verification
///   - Bundle signature verification: validates .app code signature
///
/// These protections work with macOS Hardened Runtime (applied at code signing
/// time) and SIP. They limit the usual ways of inspecting this process
/// (debugger attachment, core files, injected libraries); they are not a
/// guarantee that its memory cannot be read.

import CryptoKit
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "security")

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

/// Signed SIP self-report (`sip_enabled`): true only for Apple's default
/// configuration, never for a custom configuration with any protection off.
public func checkSIPEnabled(
    runner: SecurityCommandRunner = .live,
    configuration: SIPConfiguration? = SIPConfigurationReader.current()
) -> Bool {
    if let configuration {
        if configuration.isDefault {
            logger.info("SIP check: System Integrity Protection is at its default configuration")
        } else {
            let value = configuration.hexString
            let off = configuration.relaxedProtections.joined(separator: ", ")
            logger.error(
                "SIP check: not at the default configuration (\(value, privacy: .public)); off: \(off, privacy: .public)"
            )
        }
        return configuration.isDefault
    }
    let status = SIPStatusChecker(runner: runner).status()
    switch status {
    case .enabled:
        logger.info("SIP check: System Integrity Protection is fully enabled")
    case .enabledWithCustomConfiguration:
        logger.error("SIP check: System Integrity Protection has a custom configuration")
    case .disabled:
        logger.error("SIP check: System Integrity Protection is DISABLED")
    case .unavailable(let reason):
        logger.error("SIP check: could not determine SIP status: \(reason)")
    case .unrecognized:
        logger.error("SIP check: could not interpret csrutil output")
    }
    return sipAtDefaultConfiguration(nil, status: status)
}

// MARK: - RDMA Check

/// Check if RDMA (Remote Direct Memory Access) is disabled.
///
/// RDMA over Thunderbolt exposes IOMMU-mapped memory regions registered by
/// the RDMA runtime. It is allowed for RDMA-aware provider modes, but must be
/// reported truthfully so the coordinator can apply the correct routing policy.
/// Enabling RDMA is Apple's System Settings switch from macOS 27 (Privacy &
/// Security, after a restart); before that it requires booting into Recovery
/// OS and running `rdma_ctl enable`.
///
/// Returns true if RDMA is disabled (safe) or if rdma_ctl is not
/// available (older macOS without RDMA support).
public func checkRDMADisabled() -> Bool {
    checkRDMADisabled(runner: .live)
}

func checkRDMADisabled(runner: SecurityCommandRunner) -> Bool {
    let output: String
    do {
        output = try runner.run("/usr/bin/rdma_ctl", ["status"]).stdout
    } catch {
        // rdma_ctl not found means RDMA is not supported on this Mac
        // (pre-macOS 26.2 or hardware without Thunderbolt 5 RDMA support).
        logger.debug("RDMA check: rdma_ctl not available, assuming safe")
        return true
    }
    let disabled = output.trimmingCharacters(in: .whitespacesAndNewlines) == "disabled"

    if disabled {
        logger.debug("RDMA check: RDMA is disabled")
    } else {
        logger.debug("RDMA check: RDMA is enabled")
    }
    return disabled
}

// MARK: - Secure Boot Check

/// Historical Authenticated Root proxy retained for wire compatibility. It is
/// not presented as a local Secure Boot verdict.
public func checkSecureBootEnabled(runner: SecurityCommandRunner = .live) -> Bool {
    checkAuthenticatedRootEnabled(runner: runner)
}

// MARK: - Authenticated Root Volume

/// Signed Authenticated Root Volume self-report. `csrutil authenticated-root`
/// is primary and `diskutil info /` is the fallback; only a positive enabled or
/// sealed result returns true. "Broken" remains unconfirmed rather than being
/// treated as healthy.
public func checkAuthenticatedRootEnabled(runner: SecurityCommandRunner = .live) -> Bool {
    authenticatedRootStatus(runner: runner) ?? false
}

/// Tri-state form of `checkAuthenticatedRootEnabled`: nil when neither
/// `csrutil` nor `diskutil` produced a usable reading.
public func authenticatedRootStatus(runner: SecurityCommandRunner = .live) -> Bool? {
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

    return nil
}

/// The serving posture's reading. Only `csrutil authenticated-root status`'s
/// exact answer decides: a zero exit, an empty stderr, and stdout that is
/// exactly `Authenticated Root status: enabled` or `... disabled` (an optional
/// final period, then at most one newline); output that doesn't decode is empty. Any other answer is unread from
/// csrutil; then `diskutil info /` can only confirm a seal (`Sealed: Yes`),
/// since macOS can say "Broken" for a healthy one. Unread is nil, so a Mac
/// whose reading is unclear is never refused, only warned. The older signed
/// readings (`authenticatedRootStatus`) keep their own contract.
public func authenticatedRootPolicy(runner: SecurityCommandRunner = BootSecuritySnapshot.liveRunner) -> Bool? {
    if let result = try? runner.run("/usr/bin/csrutil", ["authenticated-root", "status"]),
       result.terminationStatus == 0, !result.wroteToStderr {
        let answer = result.stdout.hasSuffix("\n") ? String(result.stdout.dropLast()) : result.stdout
        switch answer {
        case "Authenticated Root status: enabled", "Authenticated Root status: enabled.": return true
        case "Authenticated Root status: disabled", "Authenticated Root status: disabled.": return false
        default: break
        }
    }
    if let result = try? runner.run("/usr/sbin/diskutil", ["info", "/"]), result.terminationStatus == 0 {
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Sealed:") else { continue }
            return trimmed.dropFirst("Sealed:".count).trimmingCharacters(in: .whitespaces) == "Yes" ? true : nil
        }
    }
    return nil
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
    checkHardenedRuntimeEnabled(runner: .live)
}

func checkHardenedRuntimeEnabled(runner: SecurityCommandRunner) -> Bool {
    guard let exePath = executablePath() else { return false }

    let output: String
    do {
        // codesign writes its identity and flags to stderr.
        output = try runner.run("/usr/bin/codesign", ["--display", "--verbose", exePath]).stderr
    } catch {
        logger.warning("Hardened Runtime check: failed to run codesign: \(error)")
        return false
    }

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
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errPipe

    let childExit = ProcessExitObserver()
    do {
        try childExit.run(process)
    } catch {
        logger.warning("Could not verify bundle signature: \(error)")
        return // Don't fail if codesign isn't available
    }
    // Drain the captured stream before waiting; stdout is deliberately discarded.
    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
    childExit.wait()

    if process.terminationStatus == 0 {
        logger.info("App bundle signature valid")
    } else {
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
    public let bundleSignatureValid: Bool
    public let binaryHash: String?
    /// The boot security serving depends on: the exact SIP configuration and
    /// the Secure Boot policy, reported to the coordinator.
    public let bootSecurity: BootSecuritySnapshot

    /// This posture with a later Secure Boot reading (`BootSecuritySnapshot.rereadingSecureBoot`).
    public func rereadingSecureBoot(_ reading: SecureBootReading) -> SecurityPosture {
        let bootSecurity = bootSecurity.rereadingSecureBoot(reading)
        return SecurityPosture(
            sipEnabled: sipEnabled,
            rdmaDisabled: rdmaDisabled,
            secureBootEnabled: bootSecurity.secureBoot == .full,
            authenticatedRootEnabled: authenticatedRootEnabled,
            hardenedRuntimeEnabled: hardenedRuntimeEnabled,
            antiDebugEnabled: antiDebugEnabled,
            coreDumpsDisabled: coreDumpsDisabled,
            envScrubbed: envScrubbed,
            bundleSignatureValid: bundleSignatureValid,
            binaryHash: binaryHash,
            bootSecurity: bootSecurity
        )
    }
}

/// Collect startup posture. Boot security that refuses Darkbloom serving is
/// enforced by the serve loop; the other failures are reported to the
/// coordinator, which owns the routing trust decision.
/// The serve loop's startup posture, with the process hardened. `bootSettingsCommands`
/// and `kernelSIP` stand in for the boot-settings reading's commands and kernel
/// value (the collector fixture); production passes neither. A failed Secure
/// Boot read is read again on `secureBootRetry`'s schedule before the posture
/// is returned, so the serve loop's gate sees the result. `secureBootStop` is
/// asked before the first read, between the waits' steps and after the reads:
/// once it says stop, nothing more is read or hardened, and the result is nil.
public func collectSecurityPosture(
    bootSettingsCommands: SecurityCommandRunner? = nil,
    kernelSIP: () -> SIPConfiguration? = { SIPConfigurationReader.current() },
    secureBootRetry: SecureBootReadRetry = .service,
    secureBootStop: @Sendable () async -> Bool = { false }
) async -> SecurityPosture? {
    await collectPosture(bootSettingsCommands: bootSettingsCommands, kernelSIP: kernelSIP,
                         secureBootRetry: secureBootRetry, secureBootStop: secureBootStop, hardenProcess: true)
}

#if DEBUG
/// The serve loop's test seam: the same collection without the process-wide steps
/// (debugger denial, the core limit, the environment scrub), which take no part in
/// the boot-settings decision, so a shared test host stays as it was. Debug builds only.
func collectSecurityPostureWithoutHardening(
    bootSettingsCommands: SecurityCommandRunner?,
    kernelSIP: () -> SIPConfiguration?,
    secureBootRetry: SecureBootReadRetry,
    secureBootStop: @Sendable () async -> Bool
) async -> SecurityPosture? {
    await collectPosture(bootSettingsCommands: bootSettingsCommands, kernelSIP: kernelSIP,
                         secureBootRetry: secureBootRetry, secureBootStop: secureBootStop, hardenProcess: false)
}
#endif

/// The service's Secure Boot reading (`SecureBootPolicy.readRetrying`), logging
/// why each failed read failed (the collector logs how it ended, unless a stop
/// ended it). `commands` stands in for `system_profiler` (tests and the
/// collector fixture).
func readSecureBootRetrying(commands: SecurityCommandRunner?, retry: SecureBootReadRetry,
                            stop: @Sendable () async -> Bool) async -> SecureBootReading {
    await SecureBootPolicy.readRetrying(retry, shouldStop: stop, read: { timeout in
        SecureBootPolicy.read(runner: commands ?? SecureBootPolicy.liveRunner(timeout: timeout))
    }, onFailure: { failed, next in
        let then = next.map { String(format: "reading it again in %.0f s", $0) } ?? "not reading it again"
        logger.warning(
            "Secure Boot read \(failed.attempts) failed: \(failed.failure?.rawValue ?? "", privacy: .public) (\(failed.detail, privacy: .public); \(failed.privateDetail, privacy: .private)); \(then, privacy: .public)"
        )
    })
}

/// One line for how a Secure Boot reading ended: why it is unknown, or the
/// policy when it took more than one read. `when` names the reading
/// ("at startup", "before connecting"). Text from the tool is private.
func logSecureBootReading(_ reading: SecureBootReading, when: String) {
    if let failure = reading.failure {
        logger.error(
            "Secure Boot could not be read \(when, privacy: .public) after \(reading.attempts) reads: \(failure.rawValue, privacy: .public) (\(reading.detail, privacy: .public); \(reading.privateDetail, privacy: .private)); it is reported as unknown"
        )
    } else if reading.attempts > 1 {
        logger.notice(
            "Secure Boot read \(when, privacy: .public) on read \(reading.attempts): \(reading.policy.summary, privacy: .public)"
        )
    }
}

private func collectPosture(
    bootSettingsCommands: SecurityCommandRunner?,
    kernelSIP: () -> SIPConfiguration?,
    secureBootRetry: SecureBootReadRetry,
    secureBootStop: @Sendable () async -> Bool,
    hardenProcess: Bool
) async -> SecurityPosture? {
    // A stop before or during the Secure Boot reads ends the collection there: no later probe runs, and the caller
    // adopts nothing.
    if await secureBootStop() { return nil }
    let secureBoot = await readSecureBootRetrying(commands: bootSettingsCommands, retry: secureBootRetry,
                                                  stop: secureBootStop)
    if await secureBootStop() { return nil }
    logSecureBootReading(secureBoot, when: "at startup")
    let bootSecurity = BootSecuritySnapshot.live(runner: bootSettingsCommands, kernelSIP: kernelSIP, secureBoot: secureBoot)
    let sipEnabled = bootSecurity.sipAtDefault
    for refusal in bootSecurity.servingRefusals {
        logger.error("\(refusal.name, privacy: .public): \(refusal.detail, privacy: .public)")
    }

    let rdmaDisabled = checkRDMADisabled()

    var antiDebugOk = false
    var coreDumpsOk = false
    if hardenProcess {
        // Anti-debug: PT_DENY_ATTACH + P_TRACED check
        antiDebugOk = true
        do {
            try denyDebuggerAttachment()
        } catch {
            logger.warning("PT_DENY_ATTACH failed (may already be set): \(error)")
            // Not fatal on retry -- PT_DENY_ATTACH returns EPERM if already set
            antiDebugOk = !checkDebuggerAttached()
        }

        coreDumpsOk = true
        do {
            try disableCoreDumps()
        } catch {
            logger.warning("Failed to disable core dumps: \(error)")
            coreDumpsOk = false
        }

        scrubDangerousEnvironment()
    }

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
        // The signed attestation reads its own values (AttestationBuilder); these two
        // come from the bounded reading, so startup runs no duplicate unbounded probe.
        secureBootEnabled: bootSecurity.secureBoot == .full,
        authenticatedRootEnabled: bootSecurity.authenticatedRoot == true,
        hardenedRuntimeEnabled: checkHardenedRuntimeEnabled(),
        antiDebugEnabled: antiDebugOk,
        coreDumpsDisabled: coreDumpsOk,
        envScrubbed: hardenProcess,
        bundleSignatureValid: bundleOk,
        binaryHash: selfBinaryHash(),
        bootSecurity: bootSecurity
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
    let signData = responseHashPrefix(requestId: requestId, completionTokens: completionTokens) + responseBody
    return signedResponseHash(sha256Hex(Data(signData.utf8)), identity: identity)
}

/// The same hash and signature as the `responseBody:` form, computed from the
/// response text the handler gathered, without a second copy of it.
func computeResponseAttestation(
    identity: (any AttestationSigner)?,
    requestId: String,
    completionTokens: UInt64,
    response: ResponseTextBuffer
) -> (hash: String, signature: String?) {
    let prefix = responseHashPrefix(requestId: requestId, completionTokens: completionTokens)
    return signedResponseHash(response.sha256(after: prefix).hexString, identity: identity)
}

/// What the response hash covers before the response text.
private func responseHashPrefix(requestId: String, completionTokens: UInt64) -> String {
    "\(requestId):\(completionTokens):"
}

private func signedResponseHash(
    _ responseHash: String, identity: (any AttestationSigner)?
) -> (hash: String, signature: String?) {
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
    systemVolumeHash(runner: .live)
}

func systemVolumeHash(runner: SecurityCommandRunner) -> String? {
    guard let output = try? runner.run("/usr/sbin/diskutil", ["info", "/"]).stdout else {
        return nil
    }

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
