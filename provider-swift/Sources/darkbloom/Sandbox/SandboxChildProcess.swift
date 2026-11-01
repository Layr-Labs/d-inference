import Darwin
import Foundation

/// Runs one child process for a sandbox command and waits for it from its
/// termination handler, never blocking a thread. While the child runs, Ctrl-C
/// goes to the child alone (it shares the terminal's process group) and
/// SIGTERM sent to this process is passed on, so the command can say how the
/// child ended. The child starts with default signal handling: a handler, not
/// `SIG_IGN`, is installed here, and exec resets handlers.
enum SandboxChildProcess {
    struct Exit: Equatable, Sendable {
        let status: Int32
        /// The signal that ended the child, if one did.
        let signal: Int32?

        var succeeded: Bool { signal == nil && status == 0 }
        /// Ctrl-C: killed by SIGINT, or a shell's `exit 130` after trapping it.
        var interrupted: Bool { signal == SIGINT || (signal == nil && status == 130) }
    }

    enum Output: Sendable {
        case inherit
        /// Each line, without its line break, from a reader thread.
        case lines(@Sendable (String) -> Void)
        case tail(SandboxOutputTail)
    }

    static func run(
        _ executable: URL, _ arguments: [String], currentDirectory: URL? = nil,
        closeStandardInput: Bool = false, standardOutput: Output = .inherit, standardError: Output = .inherit
    ) async throws -> Exit {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if closeStandardInput { process.standardInput = FileHandle.nullDevice }
        var captured: [(Pipe, Output)] = []
        if case .inherit = standardOutput {} else {
            let pipe = Pipe()
            process.standardOutput = pipe
            captured.append((pipe, standardOutput))
        }
        if case .inherit = standardError {} else {
            let pipe = Pipe()
            process.standardError = pipe
            captured.append((pipe, standardError))
        }

        SignalHandlers.shared.retain()
        let child = ChildReference(process)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminate.setEventHandler { child.terminate() }
        terminate.resume()
        defer {
            terminate.cancel()
            SignalHandlers.shared.release()
        }

        // Output is complete only when every reader reaches end of file; enter
        // the group before launch so a quick exit cannot finish first.
        let readers = DispatchGroup()
        captured.forEach { _ in readers.enter() }
        // A child writing to the same stdout must come after what is printed.
        fflush(stdout)
        fflush(stderr)
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let signal = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
                let exit = Exit(status: process.terminationStatus, signal: signal)
                readers.notify(queue: .global()) { continuation.resume(returning: exit) }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                captured.forEach { _ in readers.leave() }
                continuation.resume(throwing: error)
                return
            }
            for (pipe, output) in captured {
                try? pipe.fileHandleForWriting.close()
                let handle = pipe.fileHandleForReading
                DispatchQueue(label: "dev.darkbloom.sandbox.child-output").async {
                    defer { readers.leave() }
                    read(handle, into: output)
                }
            }
        }
    }

    private static func read(_ handle: FileHandle, into output: Output) {
        var splitter = SandboxLineSplitter()
        while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
            switch output {
            case .inherit: return
            case .tail(let tail): tail.append(chunk)
            case .lines(let line): splitter.append(chunk).forEach(line)
            }
        }
        if case .lines(let line) = output, let rest = splitter.finish() { line(rest) }
        try? handle.close()
    }

    private final class ChildReference: @unchecked Sendable {
        private let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { if process.isRunning { process.terminate() } }
    }

    /// No-op SIGINT and SIGTERM handlers while any child runs; the first run
    /// saves the previous handlers and the last one restores them.
    private final class SignalHandlers: @unchecked Sendable {
        static let shared = SignalHandlers()

        private let lock = NSLock()
        private var children = 0
        private var interrupt: sig_t?
        private var terminate: sig_t?

        func retain() {
            lock.withLock {
                if children == 0 {
                    interrupt = signal(SIGINT) { _ in }
                    terminate = signal(SIGTERM) { _ in }
                }
                children += 1
            }
        }

        func release() {
            lock.withLock {
                children -= 1
                guard children == 0 else { return }
                signal(SIGINT, interrupt)
                signal(SIGTERM, terminate)
            }
        }
    }
}

/// Splits output into lines; a line longer than `maximumBytes` is cut there.
struct SandboxLineSplitter {
    var maximumBytes = 64 * 1024
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Self.text(pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > maximumBytes {
            lines.append(Self.text(pending))
            pending.removeAll()
        }
        return lines
    }

    mutating func finish() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : Self.text(pending)
    }

    private static func text(_ bytes: Data) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}

/// The last `limit` bytes a child wrote, for an error report.
final class SandboxOutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int = 32 * 1024) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
        }
    }

    /// The last `count` non-empty lines.
    func lastLines(_ count: Int) -> [String] {
        let text = lock.withLock { String(decoding: data, as: UTF8.self) }
        return Array(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(count))
    }
}
