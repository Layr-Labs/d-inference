import Darwin
import Foundation
import Testing
@testable import ProviderCore

@Test func sipStatusParserRecognizesEnabledDisabledAndCustomOutput() {
    #expect(SIPStatusParser.parse("System Integrity Protection status: enabled.\n") == .enabled)
    #expect(SIPStatusParser.parse("System Integrity Protection status: disabled.\n") == .disabled)

    let custom = """
    System Integrity Protection status: enabled (Custom Configuration).

    Configuration:
        Kext Signing: disabled
        Filesystem Protections: enabled
        Debugging Restrictions: disabled
    """

    #expect(
        SIPStatusParser.parse(custom) == .enabledWithCustomConfiguration(
            disabledProtections: ["Kext Signing", "Debugging Restrictions"]
        )
    )
}

@Test func sipStatusCheckerUsesInjectedRunner() {
    let checker = SIPStatusChecker(
        runner: SecurityCommandRunner { executablePath, arguments in
            #expect(executablePath == "/usr/bin/csrutil")
            #expect(arguments == ["status"])
            return SecurityCommandResult(
                terminationStatus: 0,
                stdout: "System Integrity Protection status: enabled.\n"
            )
        }
    )

    #expect(checker.status() == .enabled)
    #expect(checker.isFullyEnabled())
}

@Test func sipStatusParserReportsUnavailableOnCommandFailure() {
    let status = SIPStatusParser.parse(
        SecurityCommandResult(
            terminationStatus: 1,
            stdout: "",
            stderr: "csrutil: failed"
        )
    )

    #expect(status == .unavailable(reason: "csrutil: failed"))
}

// MARK: - Attestation-feeding checks (checkSIPEnabled / checkSecureBootEnabled)
//
// These two functions feed the SIGNED attestation (`sip_enabled`,
// `secure_boot_enabled`). They run through an injected `SecurityCommandRunner`
// so the exact value the coordinator verifies is exercised here without
// depending on the host's boot policy.

@Test func checkSIPEnabledReflectsInjectedRunner() {
    func sip(_ stdout: String) -> SecurityCommandRunner {
        SecurityCommandRunner { path, args in
            #expect(path == "/usr/bin/csrutil")
            #expect(args == ["status"])
            return SecurityCommandResult(terminationStatus: 0, stdout: stdout)
        }
    }
    #expect(checkSIPEnabled(runner: sip("System Integrity Protection status: enabled.\n")))
    #expect(!checkSIPEnabled(runner: sip("System Integrity Protection status: disabled.\n")))
    // "enabled (Custom Configuration)" is NOT fully enabled → attests false.
    #expect(!checkSIPEnabled(runner: sip(
        """
        System Integrity Protection status: enabled (Custom Configuration).

        Configuration:
        \tKext Signing: disabled
        """
    )))
}

@Test func checkSecureBootEnabledUnavailableWhenSPiBridgeEmpty() {
    // An EMPTY SPiBridge array (anomalous on Tahoe) yields `.unavailable`, which
    // attests false — there is no sudo-free proxy fallback anymore.
    #expect(!checkSecureBootEnabled(runner: bootSecurityRunner(systemProfiler: emptyBridge)))
    // A system_profiler failure likewise attests false.
    #expect(!checkSecureBootEnabled(runner: SecurityCommandRunner { _, _ in
        SecurityCommandResult(terminationStatus: 1, stderr: "system_profiler: boom")
    }))
}

@Test func checkSecureBootEnabledViaSPiBridge() {
    // Primary path: a populated SPiBridge `ibridge_secure_boot` decides on BOTH
    // Intel T2 AND modern Apple Silicon.
    #expect(checkSecureBootEnabled(runner: bootSecurityRunner(
        systemProfiler: spiBridge("Full Security"))))
    #expect(!checkSecureBootEnabled(runner: bootSecurityRunner(
        systemProfiler: spiBridge("Medium Security"))))
    #expect(!checkSecureBootEnabled(runner: bootSecurityRunner(
        systemProfiler: spiBridge("No Security"))))
}

@Test func checkSecureBootEnabledRealAppleSiliconSPiBridge() {
    // Ground the attestation-feeding path in the EXACT real output captured on
    // Apple Silicon (M4 Max / Mac16,5 / arm64): a populated SPiBridgeDataType
    // with `ibridge_secure_boot == "Full Security"` MUST attest true.
    #expect(checkSecureBootEnabled(runner: bootSecurityRunner(
        systemProfiler: realAppleSiliconBridgeJSON)))
}

// MARK: - checkAuthenticatedRootEnabled (standalone SSV-seal attestation field)
//
// `authenticated_root_enabled` is a SEPARATE signed-attestation field, distinct
// from `secure_boot_enabled`. It reads the SSV seal sudo-free: `csrutil
// authenticated-root status` primary, `diskutil info /` fallback. Exercised here
// via an injected runner so the attested boolean is pinned without depending on
// the host's seal state.

@Test func checkAuthenticatedRootEnabledCsrutilPrimary() {
    // csrutil reports the seal directly: enabled → true, disabled → false.
    #expect(checkAuthenticatedRootEnabled(runner: bootSecurityRunner(
        systemProfiler: emptyBridge,
        authenticatedRoot: "Authenticated Root status: enabled\n")))
    #expect(!checkAuthenticatedRootEnabled(runner: bootSecurityRunner(
        systemProfiler: emptyBridge,
        authenticatedRoot: "Authenticated Root status: disabled\n")))
}

@Test func checkAuthenticatedRootEnabledDiskutilFallback() {
    // When csrutil is unreadable, fall back to diskutil's "Sealed:" line.
    #expect(checkAuthenticatedRootEnabled(runner: bootSecurityRunner(
        systemProfiler: emptyBridge, diskutil: "   Sealed:                     Yes\n")))
    #expect(!checkAuthenticatedRootEnabled(runner: bootSecurityRunner(
        systemProfiler: emptyBridge, diskutil: "   Sealed:                     No\n")))
    // macOS 26 mislabels a healthy seal "Broken" — ambiguous, so NOT confirmed.
    #expect(!checkAuthenticatedRootEnabled(runner: bootSecurityRunner(
        systemProfiler: emptyBridge, diskutil: "   Sealed:                     Broken\n")))
}

@Test func checkAuthenticatedRootEnabledUnreadableIsFalse() {
    // Both probes failing must attest false, never a false positive.
    #expect(!checkAuthenticatedRootEnabled(runner: SecurityCommandRunner { _, _ in
        SecurityCommandResult(terminationStatus: 1, stderr: "unreadable")
    }))
}

@Test func binarySHA256HasherHashesDataAndFiles() throws {
    let hasher = BinarySHA256Hasher(chunkSize: 2)
    #expect(
        hasher.hashData(Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )

    let tempDir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("payload.bin")
    try Data("abc".utf8).write(to: fileURL)
    #expect(try hasher.hashFile(at: fileURL) == hasher.hashData(Data("abc".utf8)))
}

@Test func hashFilesSortedIsStableAcrossInputOrderAndContentSensitive() throws {
    let tempDir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let first = tempDir.appendingPathComponent("a.txt")
    let second = tempDir.appendingPathComponent("b.txt")
    try Data("one".utf8).write(to: first)
    try Data("two".utf8).write(to: second)

    let hasher = BinarySHA256Hasher()
    let ordered = try hasher.hashFilesSorted([first, second])
    let reversed = try hasher.hashFilesSorted([second, first])
    #expect(ordered == reversed)

    try Data("changed".utf8).write(to: second)
    #expect(try hasher.hashFilesSorted([first, second]) != ordered)
}

@Test func runtimeHashReporterBuildsCoordinatorReadyReport() throws {
    let tempDir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let binaryURL = tempDir.appendingPathComponent("darkbloom")
    let runtimeDir = tempDir.appendingPathComponent("runtime")
    let templateDir = tempDir.appendingPathComponent("templates")
    try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: templateDir, withIntermediateDirectories: true)

    try Data("binary".utf8).write(to: binaryURL)
    try Data("runtime-a".utf8).write(to: runtimeDir.appendingPathComponent("a.swiftmodule"))
    try FileManager.default.createDirectory(
        at: runtimeDir.appendingPathComponent("__pycache__"),
        withIntermediateDirectories: true
    )
    try Data("ignored".utf8).write(to: runtimeDir.appendingPathComponent("__pycache__").appendingPathComponent("x.pyc"))
    try Data("template".utf8).write(to: templateDir.appendingPathComponent("chatml.jinja"))
    try Data("not a template".utf8).write(to: templateDir.appendingPathComponent("README.txt"))

    let reporter = RuntimeHashReporter()
    let report = try reporter.report(
        binaryURL: binaryURL,
        runtimeDirectories: [runtimeDir],
        templateDirectory: templateDir
    )

    let expectedBinaryHash = try BinarySHA256Hasher().hashFile(at: binaryURL)
    #expect(report.binaryHash == expectedBinaryHash)
    #expect(report.pythonHash == nil)
    #expect(report.runtimeHash != nil)
    #expect(report.templateHashes.keys.sorted() == ["chatml"])
    #expect(report.coordinatorRuntimeHashes.runtimeHash == report.runtimeHash)
    #expect(report.coordinatorRuntimeHashes.templateHashes == report.templateHashes)
}

@Test func statusCanonicalMatchesCoordinatorGoldenBytes() throws {
    let data = try StatusCanonical.build(StatusCanonicalInput(
        nonce: "test-nonce",
        timestamp: "2026-04-16T12:00:00Z",
        rdmaDisabled: true,
        sipEnabled: true,
        secureBootEnabled: true,
        binaryHash: "binhash",
        activeModelHash: "activemodel",
        pythonHash: "pyhash",
        runtimeHash: "rthash",
        templateHashes: [
            "chatml": "tmplhash1",
            "gemma": "tmplhash2",
        ],
        modelHashes: [
            "qwen": "modelhash1",
            "trinity": "modelhash2",
        ]
    ))
    let expected = #"{"active_model_hash":"activemodel","binary_hash":"binhash","model_hashes":{"qwen":"modelhash1","trinity":"modelhash2"},"nonce":"test-nonce","python_hash":"pyhash","rdma_disabled":true,"runtime_hash":"rthash","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"chatml":"tmplhash1","gemma":"tmplhash2"},"timestamp":"2026-04-16T12:00:00Z"}"#
    #expect(String(data: data, encoding: .utf8) == expected)
}

@Test func registrationAttestationBlobJSONOmitsHypervisorKeys() throws {
    // The registration attestation blob is signed over its exact serialized
    // bytes (sorted keys, ISO-8601 dates -- the same encoder settings
    // AttestationBuilder.buildAttestation uses). The hypervisor concept was
    // removed from the provider: pin that NO hypervisor key appears in the
    // signed blob JSON.
    let blob = AttestationBlob(
        authenticatedRootEnabled: true,
        binaryHash: "binhash",
        chipName: "Apple M4 Max",
        encryptionPublicKey: "ZW5jcnlwdGlvbi1rZXk=",
        hardwareModel: "Mac16,5",
        osVersion: "15.3.0",
        publicKey: "cHVibGljLWtleQ==",
        rdmaDisabled: true,
        secureBootEnabled: true,
        secureEnclaveAvailable: true,
        serialNumber: "C02TESTSERIAL",
        sipEnabled: true,
        systemVolumeHash: "svhash",
        timestamp: Date(timeIntervalSince1970: 1_766_000_000)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(blob)

    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["hypervisorActive"] == nil)
    #expect(object["hypervisor_active"] == nil)
    // Sanity: the blob still carries its real posture fields.
    #expect(object["sipEnabled"] as? Bool == true)
    #expect(object["rdmaDisabled"] as? Bool == true)
}

@Test func statusCanonicalOmitsEmptyFieldsAndSerializesFalse() throws {
    let minimal = try StatusCanonical.build(StatusCanonicalInput(nonce: "n", timestamp: "t"))
    #expect(String(data: minimal, encoding: .utf8) == #"{"nonce":"n","timestamp":"t"}"#)

    let explicitFalse = try StatusCanonical.build(StatusCanonicalInput(
        nonce: "n",
        timestamp: "t",
        sipEnabled: false
    ))
    #expect(String(data: explicitFalse, encoding: .utf8) == #"{"nonce":"n","sip_enabled":false,"timestamp":"t"}"#)
}

@Test func securityPostureAllowsRDMAEnabledWhenSIPIsEnabled() {
    let posture = SecurityPosture(
        sipEnabled: true,
        rdmaDisabled: false,
        secureBootEnabled: true,
        authenticatedRootEnabled: true,
        hardenedRuntimeEnabled: true,
        antiDebugEnabled: true,
        coreDumpsDisabled: true,
        envScrubbed: true,
        mdmEnrolled: false,
        bundleSignatureValid: true,
        binaryHash: "hash"
    )

    #expect(posture.isSafeToServe)
}

@Test func environmentScrubPlannerPlansWithoutMutatingEnvironment() {
    let planner = EnvironmentScrubPlanner()
    let plan = planner.plan(for: [
        "PATH": "/usr/bin",
        "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
        "PYTHONPATH": "/tmp/sitecustomize",
    ])

    #expect(plan.variableNames == ["DYLD_INSERT_LIBRARIES", "PYTHONPATH"])
    #expect(plan.removals.contains { $0.name == "DYLD_INSERT_LIBRARIES" })
    #expect(!plan.removals.contains { $0.name == "PATH" })
}

@Test func debugAttachmentProtectorUsesInjectedPtraceClient() throws {
    let recorder = PtraceRecorder()
    let protector = DebugAttachmentProtector(
        client: PtraceClient(
            ptrace: { request, pid, addr, data in
                recorder.record(request: request, pid: pid, addrIsNil: addr == nil, data: data)
                return 0
            },
            lastErrno: { 0 }
        )
    )

    #expect(try protector.denyDebuggerAttachment())
    #expect(recorder.calls == [
        PtraceCall(
            request: DebugAttachmentProtector.ptDenyAttachRequest,
            pid: 0,
            addrIsNil: true,
            data: 0
        ),
    ])
}

@Test func debugAttachmentProtectorCanBeDisabledForTests() throws {
    let protector = DebugAttachmentProtector.disabledForTests
    #expect(try protector.denyDebuggerAttachment() == false)
}

@Test func debugAttachmentProtectorReportsErrnoOnFailure() {
    let protector = DebugAttachmentProtector(
        client: PtraceClient(
            ptrace: { _, _, _, _ in -1 },
            lastErrno: { EPERM }
        )
    )

    do {
        _ = try protector.denyDebuggerAttachment()
        Issue.record("Expected PT_DENY_ATTACH failure")
    } catch let error as DebugAttachmentProtectionError {
        #expect(error == .denyAttachFailed(errno: EPERM, message: String(cString: strerror(EPERM))))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProviderCoreSecurityTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Boot-security fixtures (shared by the checkSecureBootEnabled tests)

/// An EMPTY `system_profiler -json SPiBridgeDataType` array — the fallback shape
/// seen only on older Apple Silicon / older macOS (or a sandboxed
/// `system_profiler`). Modern Apple Silicon POPULATES this array
/// (see `realAppleSiliconBridgeJSON`).
private let emptyBridge = #"{ "SPiBridgeDataType" : [ ] }"#

/// A populated `system_profiler -json SPiBridgeDataType` with `ibridge_secure_boot`.
/// This array is populated on BOTH Intel T2 AND modern Apple Silicon.
private func spiBridge(_ secureBoot: String) -> String {
    #"{ "SPiBridgeDataType" : [ { "ibridge_secure_boot" : ""# + secureBoot + #"" } ] }"#
}

/// The EXACT real `system_profiler -json SPiBridgeDataType` captured on Apple
/// Silicon (M4 Max / Mac16,5 / arm64, macOS darwin 25.5.0): a POPULATED array
/// reporting `ibridge_secure_boot == "Full Security"` — proof the data type is
/// not Intel-T2-only and not empty on modern Apple Silicon.
private let realAppleSiliconBridgeJSON = """
{
  "SPiBridgeDataType" : [
    {
      "ibridge_boot_uuid" : "A904AC62-589E-450B-8829-96ADA16DE3DC",
      "ibridge_build" : "mBoot-18000.120.36",
      "ibridge_extra_boot_policies" : " ",
      "ibridge_model_identifier_top" : "Mac16,5",
      "ibridge_sb_boot_args" : "Enabled",
      "ibridge_sb_ctrr" : "Enabled",
      "ibridge_sb_device_mdm" : "Yes",
      "ibridge_sb_manual_mdm" : "No",
      "ibridge_sb_other_kext" : "No",
      "ibridge_sb_sip" : "Enabled",
      "ibridge_sb_ssv" : "Enabled",
      "ibridge_secure_boot" : "Full Security"
    }
  ]
}
"""

/// Dispatches each boot-security probe to a fixture. Secure Boot reads only
/// `system_profiler`; the SSV-seal attestation field (`checkAuthenticatedRootEnabled`)
/// reads `csrutil authenticated-root status` (primary) and `diskutil info /`
/// (fallback). A `nil` fixture simulates that probe being unreadable.
private func bootSecurityRunner(
    systemProfiler: String,
    authenticatedRoot: String? = nil,
    diskutil: String? = nil
) -> SecurityCommandRunner {
    SecurityCommandRunner { path, args in
        switch (path, args) {
        case ("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"]):
            return SecurityCommandResult(terminationStatus: 0, stdout: systemProfiler)
        case ("/usr/bin/csrutil", ["authenticated-root", "status"]):
            guard let authenticatedRoot else {
                return SecurityCommandResult(terminationStatus: 1, stderr: "no authenticated-root fixture")
            }
            return SecurityCommandResult(terminationStatus: 0, stdout: authenticatedRoot)
        case ("/usr/sbin/diskutil", ["info", "/"]):
            guard let diskutil else {
                return SecurityCommandResult(terminationStatus: 1, stderr: "no diskutil fixture")
            }
            return SecurityCommandResult(terminationStatus: 0, stdout: diskutil)
        default:
            return SecurityCommandResult(terminationStatus: 127, stderr: "unexpected probe: \(path) \(args)")
        }
    }
}

private struct PtraceCall: Equatable {
    let request: CInt
    let pid: pid_t
    let addrIsNil: Bool
    let data: CInt
}

private final class PtraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PtraceCall] = []

    var calls: [PtraceCall] {
        lock.withLock {
            storage
        }
    }

    func record(request: CInt, pid: pid_t, addrIsNil: Bool, data: CInt) {
        lock.withLock {
            storage.append(
                PtraceCall(
                    request: request,
                    pid: pid,
                    addrIsNil: addrIsNil,
                    data: data
                )
            )
        }
    }
}
