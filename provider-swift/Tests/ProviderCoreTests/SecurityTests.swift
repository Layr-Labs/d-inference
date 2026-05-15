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
        hypervisorActive: true,
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
    let expected = #"{"active_model_hash":"activemodel","binary_hash":"binhash","hypervisor_active":true,"model_hashes":{"qwen":"modelhash1","trinity":"modelhash2"},"nonce":"test-nonce","python_hash":"pyhash","rdma_disabled":true,"runtime_hash":"rthash","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"chatml":"tmplhash1","gemma":"tmplhash2"},"timestamp":"2026-04-16T12:00:00Z"}"#
    #expect(String(data: data, encoding: .utf8) == expected)
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
