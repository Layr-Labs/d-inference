// Copyright © 2026 Eigen Labs.
//
// Catchable pre-JIT gate for explicit paged engines. MLX custom-kernel
// compilation failures can terminate the process rather than throw, so a
// packaged provider probes every model-specific specialization in a child
// process first. The parent then runs the same smoke to populate its own
// kernel cache before allocating the physical slabs.

import Foundation
import MLXLMCommon

enum PagedKernelPreflightError: Error, CustomStringConvertible {
    case childFailed(status: Int32)
    case childSignalled(signal: Int32)
    case childTimedOut(seconds: TimeInterval)
    case childWouldNotTerminate

    var description: String {
        switch self {
        case .childFailed(let status):
            return "paged kernel preflight child exited \(status)"
        case .childSignalled(let signal):
            return "paged kernel preflight child terminated by signal \(signal)"
        case .childTimedOut(let seconds):
            return "paged kernel preflight child exceeded \(seconds) seconds"
        case .childWouldNotTerminate:
            return "paged kernel preflight child survived SIGKILL"
        }
    }
}

enum PagedKernelPreflight {
    static let defaultChildTimeout: TimeInterval = 120

    typealias ChildRunner = ([PagedAttentionKernelSmokeShape]) throws -> Void

    static func run(
        layerKinds: [CBv2LayerKind],
        executableURL: URL? = Bundle.main.executableURL,
        childTimeout: TimeInterval = defaultChildTimeout,
        childRunner: ChildRunner? = nil
    ) throws {
        let shapes = PagedAttentionKernel.smokeShapes(layerKinds: layerKinds)
        if let childRunner {
            try childRunner(shapes)
        } else if
            // Resolve bin/ (or operator-added) symlinks before deriving the
            // packaged context — same rule as PagedAttentionResources.
            let executableURL = executableURL?.resolvingSymlinksInPath(),
            executableURL.lastPathComponent == "darkbloom",
            FileManager.default.isExecutableFile(atPath: executableURL.path)
        {
            try runChild(
                executableURL: executableURL,
                shapes: shapes,
                timeout: childTimeout)
        }

        // The child makes fatal compiler/driver failures catchable. Repeat
        // in the parent to populate its process-local MLXFast kernel cache,
        // so the first request compiles or dispatches no new paged variant.
        try PagedAttentionKernel.runtimeSmoke(shapes: shapes)
    }

    private static func runChild(
        executableURL: URL,
        shapes: [PagedAttentionKernelSmokeShape],
        timeout: TimeInterval
    ) throws {
        do {
            try BoundedProcess.run(
                executableURL,
                arguments: ["runtime-smoke"] + shapes.map(\.argumentValue),
                environment: ["DARKBLOOM_NO_UPDATE_CHECK": "1"],
                timeout: timeout)
        } catch BoundedProcess.Failure.exited(let status) {
            throw PagedKernelPreflightError.childFailed(status: status)
        } catch BoundedProcess.Failure.signalled(let signal) {
            throw PagedKernelPreflightError.childSignalled(signal: signal)
        } catch BoundedProcess.Failure.timedOut(let seconds) {
            throw PagedKernelPreflightError.childTimedOut(seconds: seconds)
        } catch BoundedProcess.Failure.wouldNotTerminate {
            throw PagedKernelPreflightError.childWouldNotTerminate
        }
    }
}
