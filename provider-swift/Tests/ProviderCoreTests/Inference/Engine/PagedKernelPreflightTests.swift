// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

#if canImport(Darwin)
    import Darwin
#endif

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
            childRunner: { observed = $0.nativeShapes })

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

    @Test(
        "packed child receives resolved profile and excludes native target owners",
        arguments: [EngineV2KVQuantizationSelection.balanced, .k8v4, .k8v8])
    func packedProfileAndNativeExemptions(precision: EngineV2KVQuantizationSelection) throws {
        struct ChildFailure: Error {}
        let full = layerKind()
        let short = CBv2LayerKind(
            attention: .slidingWindow(128), hasSinks: true, headDim: 64,
            kvHeads: 8, queryHeads: 64)
        let large = CBv2LayerKind(
            attention: .slidingWindow(1024), hasSinks: true, headDim: 64,
            kvHeads: 8, queryHeads: 64)
        let native = CBv2LayerKind(
            attention: .full, headDim: 256, kvHeads: 2, queryHeads: 16)
        var request: PagedKernelPreflight.Request?
        #expect(throws: ChildFailure.self) {
            try PagedKernelPreflight.run(
                layerKinds: [full, short, large, native], precision: precision,
                nativeLayerIndices: [3], executableURL: nil,
                childRunner: {
                    request = $0
                    throw ChildFailure()
                })
        }
        let captured = try #require(request)
        #expect(captured.precision == precision)
        #expect(captured.packedShapes.count == 18)
        #expect(captured.packedShapes.allSatisfy { $0.headDim == 64 })
        #expect(captured.packedShapes.contains { $0.windowSize == nil })
        #expect(captured.packedShapes.contains { $0.windowSize == 1024 })
        #expect(!captured.packedShapes.contains { $0.windowSize == 128 })
        #expect(
            captured.arguments.prefix(3) == [
                "runtime-smoke", "--kv-quantization", precision.rawValue,
            ])
    }

    @Test("real child arguments carry packed specializations before native shapes")
    func packedArgumentsReachSpawnedChild() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("paged-preflight-\(UUID().uuidString).arguments")
        defer { try? FileManager.default.removeItem(at: output) }
        let child = try makeChild(
            """
            #!/bin/bash
            printf '%s\\n' "$@" > "\(output.path)"
            exit 19
            """)
        defer { try? FileManager.default.removeItem(at: child.directory) }
        do {
            try PagedKernelPreflight.run(
                layerKinds: [layerKind()], precision: .k8v4,
                executableURL: child.executable, childTimeout: 5)
            Issue.record("failing child unexpectedly passed")
        } catch PagedKernelPreflightError.childFailed(let status, _) {
            #expect(status == 19)
        }
        let arguments = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(Array(arguments.prefix(3)) == ["runtime-smoke", "--kv-quantization", "k8v4"])
        #expect(arguments.filter { $0 == "--packed-shape" }.count == 9)
        let packed = try stride(from: 4, to: 21, by: 2).map {
            try PagedQuantizedKernelSmokeShape(argumentValue: arguments[$0])
        }
        #expect(packed.allSatisfy { $0.headDim == 64 && $0.hasSinks })
        #expect(arguments.last == layerKindSmokeValue())
    }

    private func layerKindSmokeValue() -> String {
        PagedAttentionKernel.smokeShapes(layerKinds: [layerKind()])[0].argumentValue
    }

    @Test("large child diagnostics cannot block the preflight")
    func noisyChildCannotDeadlock() throws {
        let child = try makeChild(
            """
            #!/bin/bash
            printf 'paged-preflight-start-marker\\n' >&2
            i=0
            while [ "$i" -lt 20000 ]; do
                printf 'paged-kernel-compiler-diagnostic-0123456789\\n' >&2
                i=$((i + 1))
            done
            printf 'paged-preflight-final-diagnostic\\n' >&2
            exit 9
            """)
        defer { try? FileManager.default.removeItem(at: child.directory) }

        do {
            try PagedKernelPreflight.run(
                layerKinds: [layerKind()],
                executableURL: child.executable,
                childTimeout: 5)
            Issue.record("noisy failing child unexpectedly passed")
        } catch PagedKernelPreflightError.childFailed(let status, let tail) {
            #expect(status == 9)
            // The child's own message IS the diagnosis. Discarding it cost an
            // hour: a binary copied without its SwiftPM resource bundle made
            // `runtime-smoke` exit 1 saying exactly that, the message was
            // dropped, `.auto` degraded silently, and three runs that looked
            // like clean paged arms were contiguous. Assert the tail SURVIVES
            // and that it is the END of the stream -- this child emits 20,000
            // lines, so a tail that kept the head would carry no diagnosis at
            // all on a real compiler failure.
            let tail = try #require(tail, "the child's stderr must reach the caller")
            #expect(tail.contains("paged-kernel-compiler-diagnostic"))
            #expect(
                tail.hasSuffix("paged-preflight-final-diagnostic"),
                "the final diagnostic must survive a full stderr buffer")
            #expect(
                !tail.contains("paged-preflight-start-marker"),
                "the bounded result must retain the tail, not the head")
            #expect(tail.count <= 2048, "tail must stay bounded on a chatty child")
        } catch {
            Issue.record("unexpected preflight error: \(error)")
        }
    }

    @Test("a short diagnostic from a fast-exiting child still reaches the caller")
    func shortDiagnosticSurvivesTheRace() throws {
        // The race the drain closes: `waitUntilExit()` reaps the CHILD, not
        // the readability handler. A child that writes one line and exits
        // immediately is the worst case -- fewest bytes, least time for the
        // callback to run, and the case where the message matters most
        // because it is the whole diagnosis.
        let child = try makeChild(
            """
            #!/bin/bash
            printf 'missing SwiftPM resource pagedattention.metal\\n' >&2
            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: child.directory) }

        do {
            try PagedKernelPreflight.run(
                layerKinds: [layerKind()],
                executableURL: child.executable,
                childTimeout: 5)
            Issue.record("failing child unexpectedly passed")
        } catch PagedKernelPreflightError.childFailed(let status, let tail) {
            #expect(status == 1)
            let tail = try #require(tail, "a fast child's stderr must not be lost to the race")
            #expect(tail.contains("pagedattention.metal"))
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
                // 2s, not 0.5: sibling tests in this suite run
                // PagedAttentionKernel.runtimeSmoke on REAL Metal kernels in
                // parallel, and their in-process compile load can delay the
                // child's bash startup past a half-second deadline — the pid
                // file then never exists and the kill assertion below reads
                // as a missing-file error. The deadline only needs to be
                // SHORT relative to the 120s production default; it does not
                // need to race compiler contention.
                childTimeout: 2.0)
            Issue.record("hung child unexpectedly passed")
        } catch PagedKernelPreflightError.childTimedOut(let seconds) {
            #expect(seconds == 2.0)
            #expect(ProcessInfo.processInfo.systemUptime - started < 12)
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
