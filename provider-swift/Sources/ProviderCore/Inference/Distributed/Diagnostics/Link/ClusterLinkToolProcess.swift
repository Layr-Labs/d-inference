import Foundation
import Darwin

/// Runs one fixed tool as a direct child: no shell, the null device as
/// standard input, a three-variable environment, a hard deadline and a bounded
/// output capture.
enum ClusterLinkToolProcess {
    enum Execution: Equatable, Sendable {
        case exited(status: Int32, output: String)
        /// It could not be started, was ended by a signal, or its output could not be read.
        case abnormal
        case timedOut
        case outputTooLarge
    }

    /// How long a killed child is awaited before it is left to the kernel.
    private static let reapTimeoutNanoseconds: UInt64 = 1_000_000_000

    /// For the read-only tools: only standard output of a clean exit counts,
    /// and standard error is discarded.
    static func run(executable: String, arguments: [String], deadline: UInt64,
                    maximumOutputBytes: Int) -> ClusterLinkToolOutcome {
        switch execute(executable: executable, arguments: arguments, deadline: deadline,
                       maximumOutputBytes: maximumOutputBytes, mergingStandardError: false) {
        case .exited(status: 0, let output): return .output(output)
        case .exited, .abnormal: return .unavailable
        case .timedOut: return .timedOut
        case .outputTooLarge: return .outputTooLarge
        }
    }

    /// `deadline` is a `DispatchTime` uptime in nanoseconds. A child still
    /// running at the deadline is killed, and its exit is awaited for at most
    /// `reapTimeoutNanoseconds` more. With `mergingStandardError` the capture
    /// also holds what the tool said about a failure; otherwise that is discarded.
    static func execute(executable: String, arguments: [String], deadline: UInt64, maximumOutputBytes: Int,
                        mergingStandardError: Bool) -> Execution {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return .timedOut }
        let child = Process(), output = Pipe()
        // Foundation closes a pipe only when it releases the object, which an
        // undrained autorelease pool can postpone until the process exits.
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = mergingStandardError ? output : FileHandle.nullDevice
        let reader = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(reader, F_GETFL)
        guard flags >= 0, fcntl(reader, F_SETFL, flags | O_NONBLOCK) == 0 else { return .abnormal }
        do { try child.run() } catch { return .abnormal }
        defer {
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            // SIGKILL cannot be caught, yet a child inside an uninterruptible
            // driver call exits only when that call returns. It must not hold
            // the inspection past its bound.
            let reapDeadline = DispatchTime.now().uptimeNanoseconds + reapTimeoutNanoseconds
            while child.isRunning, DispatchTime.now().uptimeNanoseconds < reapDeadline { usleep(2_000) }
        }
        // Only the child may hold the write end, or end-of-file never arrives.
        try? output.fileHandleForWriting.close()

        var captured = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timedOut }
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            let status = Darwin.poll(&descriptor, 1, Int32(min(50, (deadline - now) / 1_000_000 + 1)))
            if status == 0 || (status < 0 && errno == EINTR) { continue }
            guard status > 0 else { return .abnormal }
            let count = Darwin.read(reader, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count >= 0 else { return .abnormal }
            if count == 0 { break }
            guard count <= maximumOutputBytes - captured.count else { return .outputTooLarge }
            captured.append(contentsOf: buffer.prefix(count))
        }
        while child.isRunning {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return .timedOut }
            usleep(2_000)
        }
        guard child.terminationReason == .exit else { return .abnormal }
        return .exited(status: child.terminationStatus, output: String(decoding: captured, as: UTF8.self))
    }
}
