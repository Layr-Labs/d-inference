// Copyright © 2026 Eigen Labs.
//
// Catchable pre-JIT gate for explicit paged engines. MLX custom-kernel
// compilation failures can terminate the process rather than throw, so a
// packaged provider probes the selected native and packed kernel families in a child
// process first. The parent then runs the same smoke to populate its own
// kernel cache before allocating the physical slabs.

import Foundation
import MLXLMCommon

enum PagedKernelPreflightError: Error, CustomStringConvertible {
    case childFailed(status: Int32, stderrTail: String?)
    case childSignalled(signal: Int32)
    case childTimedOut(seconds: TimeInterval)
    case childWouldNotTerminate

    var description: String {
        switch self {
        case .childFailed(let status, let tail):
            guard let tail, !tail.isEmpty else {
                return "paged kernel preflight child exited \(status)"
            }
            return "paged kernel preflight child exited \(status): \(tail)"
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

    struct Request {
        let nativeShapes: [PagedAttentionKernelSmokeShape]
        let packedShapes: [PagedQuantizedKernelSmokeShape]
        let precision: EngineV2KVQuantizationSelection

        var arguments: [String] {
            ["runtime-smoke", "--kv-quantization", precision.rawValue]
                + packedShapes.flatMap { ["--packed-shape", $0.argumentValue] }
                + nativeShapes.map(\.argumentValue)
        }
    }

    typealias ChildRunner = (Request) throws -> Void

    static func run(
        layerKinds: [CBv2LayerKind],
        precision: EngineV2KVQuantizationSelection = .native,
        nativeLayerIndices: Set<Int> = [],
        executableURL: URL? = Bundle.main.executableURL,
        childTimeout: TimeInterval = defaultChildTimeout,
        childRunner: ChildRunner? = nil
    ) throws {
        let shapes = PagedAttentionKernel.smokeShapes(layerKinds: layerKinds)
        let packed =
            try precision.configuration.map {
                try PagedQuantizedKernelSmoke.smokeShapes(
                    layerKinds: layerKinds, quantization: $0,
                    nativeLayerIndices: nativeLayerIndices)
            } ?? []
        let request = Request(nativeShapes: shapes, packedShapes: packed, precision: precision)
        if let childRunner {
            try childRunner(request)
        } else if // Resolve bin/ (or operator-added) symlinks before deriving the
        // packaged context — same rule as PagedAttentionResources.
        let executableURL = executableURL?.resolvingSymlinksInPath(),
            executableURL.lastPathComponent == "darkbloom",
            FileManager.default.isExecutableFile(atPath: executableURL.path)
        {
            try runChild(
                executableURL: executableURL,
                request: request,
                timeout: childTimeout)
        }

        // The child makes fatal compiler/driver failures catchable. Repeat
        // in the parent to populate its process-local MLXFast kernel cache,
        // before publishing the serving pool. The bounded probe exercises
        // selected geometry/dtype variants rather than private request data.
        try PagedAttentionKernel.runtimeSmoke(shapes: shapes)
        if let quantization = precision.configuration {
            try PagedQuantizedKernelSmoke.runtimeSmoke(shapes: packed, quantization: quantization)
        }
    }

    private static func runChild(
        executableURL: URL,
        request: Request,
        timeout: TimeInterval
    ) throws {
        do {
            var environment = try PackagedRuntimeSmoke.retainedValidationEnvironment()
            environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
            try BoundedProcess.run(
                executableURL,
                arguments: request.arguments,
                environment: environment,
                timeout: timeout,
                // The child's own message is the diagnosis. A missing
                // SwiftPM resource bundle beside a relocated binary is a
                // PACKAGING fault, and without this it reads as a hardware
                // verdict on a perfectly capable machine.
                captureStderrTail: 2048)
        } catch BoundedProcess.Failure.exited(let status, let tail) {
            throw PagedKernelPreflightError.childFailed(status: status, stderrTail: tail)
        } catch BoundedProcess.Failure.signalled(let signal) {
            throw PagedKernelPreflightError.childSignalled(signal: signal)
        } catch BoundedProcess.Failure.timedOut(let seconds) {
            throw PagedKernelPreflightError.childTimedOut(seconds: seconds)
        } catch BoundedProcess.Failure.wouldNotTerminate {
            throw PagedKernelPreflightError.childWouldNotTerminate
        }
    }
}
