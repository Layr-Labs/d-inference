import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum BoundedProcess {
    enum Failure: Error, LocalizedError, CustomStringConvertible {
        case exited(status: Int32, stderrTail: String? = nil)
        case signalled(signal: Int32)
        case timedOut(seconds: TimeInterval)
        case wouldNotTerminate

        var description: String {
            switch self {
            case .exited(let status, let tail):
                guard let tail, !tail.isEmpty else { return "process exited \(status)" }
                return "process exited \(status): \(tail)"
            case .signalled(let signal):
                return "process terminated by signal \(signal)"
            case .timedOut(let seconds):
                return "process exceeded \(seconds) seconds"
            case .wouldNotTerminate:
                return "process did not terminate after SIGKILL"
            }
        }

        var errorDescription: String? { description }
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        captureStderrTail: Int = 0
    ) throws {
        try runProcess(
            executable,
            arguments: arguments,
            environment: environment,
            standardOutput: FileHandle.nullDevice,
            timeout: timeout,
            captureStderrTail: captureStderrTail)
    }

    /// Run a bounded child while retaining stdout for signed-artifact
    /// assertions. A temporary file avoids the pipe backpressure deadlock that
    /// would otherwise let a verbose child fill its pipe before termination.
    static func runCapturingStandardOutput(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-child-\(UUID().uuidString).stdout")
        guard FileManager.default.createFile(
            atPath: outputURL.path, contents: nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        try runProcess(
            executable,
            arguments: arguments,
            environment: environment,
            standardOutput: output,
            timeout: timeout,
            captureStderrTail: 0)
        try output.synchronize()
        try output.close()
        return try Data(contentsOf: outputURL)
    }

    private static func runProcess(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]?,
        standardOutput: Any,
        timeout: TimeInterval,
        captureStderrTail: Int
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(
                environment,
                uniquingKeysWith: { _, override in override })
        }
        process.standardOutput = standardOutput

        // A discarded stderr costs more than it saves. When the child fails,
        // its own message is the entire actionable content -- a preflight
        // that exits 1 because its resource bundle was not copied beside the
        // binary says exactly that, and reporting only "child exited 1" sent
        // two investigations down wrong paths for an hour.
        //
        // Drained CONCURRENTLY: a pipe nobody reads blocks the child once it
        // fills, which would turn a chatty failure into a timeout. The tail
        // is bounded so a child that streams cannot grow this unboundedly.
        var stderrPipe: Pipe?
        let tailBox = StderrTailBox(limit: captureStderrTail)
        let drained = DispatchSemaphore(value: 0)
        if captureStderrTail > 0 {
            let pipe = Pipe()
            stderrPipe = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    drained.signal()
                    return
                }
                tailBox.append(chunk)
            }
        } else {
            process.standardError = FileHandle.nullDevice
        }
        // Drain to EOF before anyone reads the tail. `waitUntilExit()` says
        // the CHILD is gone, not that the readability handler has consumed
        // the pipe -- a child that writes a short diagnostic and exits fast
        // can be reaped before its bytes are delivered, and then the tail
        // reads empty and the diagnosis is lost exactly when it is shortest
        // and most useful. The handler signals on the zero-length read that
        // means EOF; the wait is bounded so a stuck reader cannot outlive
        // the process it was observing.
        defer {
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            try? stderrPipe?.fileHandleForReading.close()
        }
        try process.run()

        guard waitForExit(process, timeout: timeout) else {
            process.terminate()
            if !waitForExit(process, timeout: 2) {
                forceKill(process)
                guard waitForExit(process, timeout: 2) else {
                    throw Failure.wouldNotTerminate
                }
            }
            process.waitUntilExit()
            throw Failure.timedOut(seconds: timeout)
        }
        process.waitUntilExit()

        guard process.terminationReason == .exit else {
            throw Failure.signalled(signal: process.terminationStatus)
        }
        guard process.terminationStatus == 0 else {
            if captureStderrTail > 0 { _ = drained.wait(timeout: .now() + 2) }
            throw Failure.exited(
                status: process.terminationStatus, stderrTail: tailBox.tail())
        }
    }

    private static func waitForExit(
        _ process: Process,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    private static func forceKill(_ process: Process) {
        #if canImport(Darwin)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        #else
        process.terminate()
        #endif
    }
}

/// Bounded, thread-safe tail buffer for a child's stderr.
///
/// The readability handler fires on an arbitrary queue, so the buffer needs a
/// lock; and it keeps only the LAST `limit` bytes, because the useful part of
/// a failing process's stderr is the end.
private final class StderrTailBox: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        guard limit > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    func tail() -> String? {
        guard limit > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty,
            let text = String(data: buffer, encoding: .utf8)
        else { return nil }
        var collapsed = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        // The BYTE buffer is bounded, but collapsing each newline into " | "
        // is a 1 -> 3 expansion, so the rendered string can exceed the limit
        // the caller asked for. Bound what actually reaches them: this rides
        // an error description that may land in a heartbeat field.
        if collapsed.count > limit {
            collapsed = String(collapsed.suffix(limit))
        }
        return collapsed.isEmpty ? nil : collapsed
    }
}
