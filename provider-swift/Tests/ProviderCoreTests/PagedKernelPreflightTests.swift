// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing
#if canImport(Darwin)
import Darwin
#endif

@testable import ProviderCore

@Suite("Paged kernel process preflight", .serialized)
struct PagedKernelPreflightTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("child probe sees every model-specific variant before parent pre-JIT")
    func modelSpecificVariants() throws {
        let owner = CBv2LayerKind(
            attention: .full,
            hasSinks: true,
            headDim: 64,
            kvHeads: 8,
            queryHeads: 64)
        var borrower = owner
        borrower.sharesKVWithLayer = 0
        var observed: [PagedAttentionKernelSmokeShape] = []

        try PagedKernelPreflight.run(
            layerKinds: [owner, borrower],
            executableURL: nil,
            childRunner: { observed = $0 })

        #expect(observed.count == 2)
        #expect(observed.contains { $0.hasWrite })
        #expect(observed.contains { !$0.hasWrite })
        #expect(observed.allSatisfy { $0.hasSinks })
    }

    @Test("child crash/failure is catchable and blocks parent construction")
    func childFailureIsCatchable() {
        struct ChildFailure: Error {}
        let kind = CBv2LayerKind(
            attention: .full,
            hasSinks: true,
            headDim: 64,
            kvHeads: 8,
            queryHeads: 64)
        #expect(throws: ChildFailure.self) {
            try PagedKernelPreflight.run(
                layerKinds: [kind],
                executableURL: nil,
                childRunner: { _ in throw ChildFailure() })
        }
    }

    @Test("large child diagnostics cannot block the preflight")
    func noisyChildCannotDeadlock() throws {
        let child = try makeChild(
            """
            #!/bin/bash
            i=0
            while [ "$i" -lt 20000 ]; do
                printf 'paged-kernel-compiler-diagnostic-0123456789\\n' >&2
                i=$((i + 1))
            done
            exit 9
            """)
        defer { try? FileManager.default.removeItem(at: child.directory) }

        do {
            try PagedKernelPreflight.run(
                layerKinds: [layerKind()],
                executableURL: child.executable,
                childTimeout: 5)
            Issue.record("noisy failing child unexpectedly passed")
        } catch PagedKernelPreflightError.childFailed(let status) {
            #expect(status == 9)
        } catch {
            Issue.record("unexpected preflight error: \(error)")
        }
    }

    @Test("hung child is terminated at the preflight deadline")
    func hungChildTimesOut() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("paged-preflight-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let child = try makeChild(
            """
            #!/bin/bash
            trap '' TERM
            printf '%s\\n' "$$" > "\(pidFile.path)"
            while :; do :; done
            """)
        defer { try? FileManager.default.removeItem(at: child.directory) }
        let started = ProcessInfo.processInfo.systemUptime

        do {
            try PagedKernelPreflight.run(
                layerKinds: [layerKind()],
                executableURL: child.executable,
                childTimeout: 0.5)
            Issue.record("hung child unexpectedly passed")
        } catch PagedKernelPreflightError.childTimedOut(let seconds) {
            #expect(seconds == 0.5)
            #expect(ProcessInfo.processInfo.systemUptime - started < 4)
            #if canImport(Darwin)
            let pidText = try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = try #require(Int32(pidText))
            #expect(Darwin.kill(pid, 0) == -1)
            #endif
        } catch {
            Issue.record("unexpected preflight error: \(error)")
        }
    }

    private func layerKind() -> CBv2LayerKind {
        CBv2LayerKind(
            attention: .full,
            hasSinks: true,
            headDim: 64,
            kvHeads: 8,
            queryHeads: 64)
    }

    private func makeChild(
        _ script: String
    ) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "paged-preflight-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("darkbloom")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
        return (directory, executable)
    }
}
