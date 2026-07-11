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
    case childFailed(status: Int32, output: String)
    case childSignalled(signal: Int32, output: String)

    var description: String {
        switch self {
        case .childFailed(let status, let output):
            return "paged kernel preflight child exited \(status): \(output)"
        case .childSignalled(let signal, let output):
            return "paged kernel preflight child terminated by signal \(signal): \(output)"
        }
    }
}

enum PagedKernelPreflight {
    typealias ChildRunner = ([PagedAttentionKernelSmokeShape]) throws -> Void

    static func run(
        layerKinds: [CBv2LayerKind],
        executableURL: URL? = Bundle.main.executableURL,
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
            try runChild(executableURL: executableURL, shapes: shapes)
        }

        // The child makes fatal compiler/driver failures catchable. Repeat
        // in the parent to populate its process-local MLXFast kernel cache,
        // so the first request compiles or dispatches no new paged variant.
        try PagedAttentionKernel.runtimeSmoke(shapes: shapes)
    }

    private static func runChild(
        executableURL: URL,
        shapes: [PagedAttentionKernelSmokeShape]
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["runtime-smoke"] + shapes.map(\.argumentValue)
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["DARKBLOOM_NO_UPDATE_CHECK": "1"],
            uniquingKeysWith: { _, override in override })
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationReason == .exit else {
            throw PagedKernelPreflightError.childSignalled(
                signal: process.terminationStatus,
                output: text)
        }
        guard process.terminationStatus == 0 else {
            throw PagedKernelPreflightError.childFailed(
                status: process.terminationStatus,
                output: text)
        }
    }
}
