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
    #expect(checkSIPEnabled(runner: sip(
        """
        System Integrity Protection status: enabled (Custom Configuration).

        Configuration:
        \tKext Signing: disabled
        """
    )))
}

@Test func authenticatedRootFeedsTheSecureBootCompatibilityProxy() {
    let enabled = authenticatedRootRunner(csrutil: "Authenticated Root status: enabled\n")
    let disabled = authenticatedRootRunner(csrutil: "Authenticated Root status: disabled\n")
    #expect(checkAuthenticatedRootEnabled(runner: enabled))
    #expect(checkSecureBootEnabled(runner: enabled))
    #expect(!checkAuthenticatedRootEnabled(runner: disabled))
    #expect(!checkSecureBootEnabled(runner: disabled))

    #expect(checkAuthenticatedRootEnabled(runner: authenticatedRootRunner(
        diskutil: "   Sealed: Yes\n")))
    for value in ["No", "Broken"] {
        #expect(!checkAuthenticatedRootEnabled(runner: authenticatedRootRunner(
            diskutil: "   Sealed: \(value)\n")))
    }
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
        chipFamily: "M5",
        chipName: "Apple M4 Max",
        encryptionPublicKey: "ZW5jcnlwdGlvbi1rZXk=",
        hardwareModel: "Mac16,5",
        metallibHash: "metallibhash",
        osVersion: "15.3.0",
        publicKey: "cHVibGljLWtleQ==",
        rdmaDisabled: true,
        runtimeCapabilities: [.appleM5, .mlxNAX],
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
    #expect(object["chipFamily"] as? String == "M5")
    #expect(object["metallibHash"] as? String == "metallibhash")
    #expect(object["runtimeCapabilities"] as? [String] == ["apple_m5", "mlx_nax"])
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

private func authenticatedRootRunner(
    csrutil: String? = nil,
    diskutil: String? = nil
) -> SecurityCommandRunner {
    SecurityCommandRunner { path, args in
        switch (path, args) {
        case ("/usr/bin/csrutil", ["authenticated-root", "status"]):
            guard let csrutil else {
                return SecurityCommandResult(terminationStatus: 1, stderr: "no authenticated-root fixture")
            }
            return SecurityCommandResult(terminationStatus: 0, stdout: csrutil)
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

@Test func processEvidenceCanonicalV1MatchesCoordinatorGoldenBytes() throws {
    let input = ProcessEvidenceCanonicalInput(
        coordinatorNonce: "nonce-v1",
        coordinatorTimestamp: "2026-08-30T12:00:00Z",
        coordinatorSessionId: "session-123",
        challengeGeneration: "generation-abc",
        evidenceExpiresAt: "2026-08-30T12:10:00Z",
        sePublicKey: "se-public",
        serialNumber: "SERIAL-1",
        processPublicKey: "process-public",
        binaryHash: "binary-hash",
        providerVersion: "0.8.15",
        providerPlatform: "macos-arm64",
        providerBackend: "mlx-swift",
        runtimeHash: "runtime-hash",
        metallibHash: "metallib-hash",
        sipEnabled: true,
        secureBootEnabled: true
    )
    let canonical = try ProcessEvidenceCanonical.buildV1(input)
    let expected = #"{"binary_hash":"binary-hash","challenge_generation":"generation-abc","coordinator_nonce":"nonce-v1","coordinator_session_id":"session-123","coordinator_timestamp":"2026-08-30T12:00:00Z","domain":"darkbloom.process_evidence","evidence_expires_at":"2026-08-30T12:10:00Z","metallib_hash":"metallib-hash","process_public_key":"process-public","provider_backend":"mlx-swift","provider_platform":"macos-arm64","provider_version":"0.8.15","runtime_hash":"runtime-hash","se_public_key":"se-public","secure_boot_enabled":true,"serial_number":"SERIAL-1","sip_enabled":true,"version":"process_evidence_v1"}"#
    #expect(String(decoding: canonical, as: UTF8.self) == expected)
}

@Test func processEvidenceCanonicalV1PreservesNilAndFalse() throws {
    var input = ProcessEvidenceCanonicalInput(
        coordinatorNonce: "", coordinatorTimestamp: "", coordinatorSessionId: "",
        challengeGeneration: "", evidenceExpiresAt: "", sePublicKey: "",
        serialNumber: "", processPublicKey: "", binaryHash: "", providerVersion: "",
        providerPlatform: "", providerBackend: "", runtimeHash: "", metallibHash: "",
        sipEnabled: nil, secureBootEnabled: nil
    )
    let omitted = String(decoding: try ProcessEvidenceCanonical.buildV1(input), as: UTF8.self)
    input.sipEnabled = false
    let explicitFalse = String(
        decoding: try ProcessEvidenceCanonical.buildV1(input), as: UTF8.self)
    #expect(!omitted.contains("sip_enabled"))
    #expect(explicitFalse.contains(#""sip_enabled":false"#))
    #expect(omitted != explicitFalse)
}

@Test func processEvidenceCanonicalV1MutationMatrix() throws {
    let base = ProcessEvidenceCanonicalInput(
        coordinatorNonce: "n", coordinatorTimestamp: "t", coordinatorSessionId: "s",
        challengeGeneration: "g", evidenceExpiresAt: "e", sePublicKey: "se",
        serialNumber: "serial", processPublicKey: "pk", binaryHash: "bin",
        providerVersion: "v", providerPlatform: "platform", providerBackend: "backend",
        runtimeHash: "runtime", metallibHash: "metal", sipEnabled: true,
        secureBootEnabled: true
    )
    let golden = try ProcessEvidenceCanonical.buildV1(base)
    var variants: [ProcessEvidenceCanonicalInput] = []
    var value = base; value.processPublicKey += "x"; variants.append(value)
    value = base; value.sePublicKey += "x"; variants.append(value)
    value = base; value.serialNumber += "x"; variants.append(value)
    value = base; value.coordinatorNonce += "x"; variants.append(value)
    value = base; value.coordinatorSessionId += "x"; variants.append(value)
    value = base; value.challengeGeneration += "x"; variants.append(value)
    value = base; value.evidenceExpiresAt += "x"; variants.append(value)
    value = base; value.binaryHash += "x"; variants.append(value)
    value = base; value.providerVersion += "x"; variants.append(value)
    value = base; value.providerBackend += "x"; variants.append(value)
    value = base; value.runtimeHash += "x"; variants.append(value)
    value = base; value.metallibHash += "x"; variants.append(value)
    value = base; value.sipEnabled = false; variants.append(value)
    value = base; value.secureBootEnabled = false; variants.append(value)
    for candidate in variants {
        #expect(try ProcessEvidenceCanonical.buildV1(candidate) != golden)
    }
}
