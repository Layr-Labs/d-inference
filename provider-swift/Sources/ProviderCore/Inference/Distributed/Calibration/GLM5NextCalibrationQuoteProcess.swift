import Darwin
import Foundation
import DarkbloomClusterProcess

/// Owns one metadata-only child until observed exit. A timed-out waiter never
/// releases that ownership; the pump retains itself until the child is reaped.
final class GLM5NextCalibrationQuoteProcess: @unchecked Sendable {
    enum Failure: Error { case invalidLaunch, cancelled, deadline, output, childFailed, unresolved }
    private let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private let exit = ClusterProcessExit(), condition = NSCondition()
    private let preflight: () throws -> Void
    private let credential: Data
    let deadline: UInt64
    private var started = false, completed = false, observed = false
    private var failure: Failure?
    private var bytes: Data?, tail = Data()
    private var pid: Int32?, birth: Double?
    var observedExit: Bool { condition.lock(); defer { condition.unlock() }; return observed }
    var diagnosticTail: Data { condition.lock(); defer { condition.unlock() }; return tail }

    convenience init(prepared: GLM5NextCalibrationQuoteLaunch.Prepared) throws {
        let launch = prepared.launch
        guard let index = launch.arguments.firstIndex(of: "--deadline-uptime-nanoseconds"),
              launch.arguments.indices.contains(index + 1), let deadline = UInt64(launch.arguments[index + 1]) else {
            throw Failure.invalidLaunch
        }
        try self.init(launch: launch, deadline: deadline, preflight: { try prepared.requireUnchanged() })
    }

    /// Internal actual-child fixture seam. Installed callers use Prepared above.
    init(launch: ClusterWorkerLaunch, deadline: UInt64, preflight: @escaping () throws -> Void) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now, deadline - now <= 300_000_000_000,
              launch.executable.isFileURL, launch.executable.path.hasPrefix("/"),
              let credential = launch.initialInput, !credential.isEmpty, credential.count <= 4096,
              credential.last == 10, credential.filter({ $0 == 10 }).count == 1 else { throw Failure.invalidLaunch }
        self.deadline = deadline; self.credential = credential; self.preflight = preflight
        child.executableURL = launch.executable; child.arguments = launch.arguments; child.environment = launch.environment
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        for handle in [input.fileHandleForWriting, output.fileHandleForReading, errors.fileHandleForReading] {
            let fd = handle.fileDescriptor, flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.invalidLaunch }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.invalidLaunch }
    }

    func start() throws {
        condition.lock()
        guard !started, failure == nil else { condition.unlock(); throw Failure.invalidLaunch }
        started = true
        do {
            // Retains the exact Prepared selection/file fence; no cached permit.
            try preflight()
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.deadline }
            try exit.run(child)
            pid = child.processIdentifier; birth = ClusterProcessTable.startTime(of: child.processIdentifier)
        } catch {
            failure = .invalidLaunch; completed = true; condition.broadcast(); condition.unlock()
            closeAll(); throw error
        }
        condition.unlock()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        DispatchQueue(label: "darkbloom.glm.quote.child").async { self.pump() }
    }
    func cancel() { fail(.cancelled) }
    private func fail(_ reason: Failure) {
        condition.lock(); defer { condition.unlock() }
        if !completed && failure == nil { failure = reason }
    }
    private var fault: Failure? { condition.lock(); defer { condition.unlock() }; return failure }
    func waitUntilExited(deadline: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while !completed && DispatchTime.now().uptimeNanoseconds < deadline {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
        return completed && observed
    }
    func response() throws -> Data {
        condition.lock(); defer { condition.unlock() }
        guard completed, observed else { throw Failure.unresolved }
        if let failure { throw failure }
        guard let bytes else { throw Failure.output }
        return bytes
    }
    private func ownsRunningChild() -> Bool {
        guard !exit.hasExited, child.isRunning, let pid, let birth else { return false }
        return ClusterProcessTable.startTime(of: pid) == birth
    }
    private func closeAll() {
        for handle in [input.fileHandleForReading, input.fileHandleForWriting, output.fileHandleForReading,
                       output.fileHandleForWriting, errors.fileHandleForReading, errors.fileHandleForWriting] { try? handle.close() }
    }
    private func pump() {
        defer { closeAll() }
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        var open = [true, true], inputOpen = true, offset = 0, data = Data(), stderrCount = 0
        var termAt: UInt64?, killed = false, exitAt: UInt64?
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { fail(.deadline) }
            if fault != nil {
                if inputOpen { try? input.fileHandleForWriting.close(); inputOpen = false }
                // This child owns no model/GPU workload. Cancellation may signal
                // promptly, but never signals an unverified/reused PID.
                if ownsRunningChild() {
                    if termAt == nil { child.terminate(); termAt = now }
                    else if !killed, now - termAt! >= 1_000_000_000 {
                        _ = Darwin.kill(child.processIdentifier, SIGKILL); killed = true
                    }
                }
            }
            var fds = handles.enumerated().map { pollfd(fd: open[$0.offset] ? $0.element.fileDescriptor : -1, events: Int16(POLLIN), revents: 0) }
            fds.append(pollfd(fd: inputOpen ? input.fileHandleForWriting.fileDescriptor : -1, events: Int16(POLLOUT), revents: 0))
            let count = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 20) }
            if count < 0 && errno != EINTR { fail(.output) }
            for index in 0..<2 where fds[index].revents != 0 {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(fds[index].fd, &buffer, buffer.count)
                if n > 0 {
                    if index == 0 {
                        if n > 65_537 - data.count { fail(.output); open[index] = false; try? handles[index].close() }
                        else {
                            data.append(contentsOf: buffer.prefix(n))
                            if let lf = data.firstIndex(of: 10), lf != data.index(before: data.endIndex) { fail(.output) }
                        }
                    } else {
                        stderrCount += n
                        condition.lock(); tail.append(contentsOf: buffer.prefix(n))
                        if tail.count > 4096 { tail.removeFirst(tail.count - 4096) }; condition.unlock()
                        if stderrCount > 65_536 { fail(.output); open[index] = false; try? handles[index].close() }
                    }
                } else if n == 0 { open[index] = false }
                else if errno != EAGAIN && errno != EINTR { fail(.output); open[index] = false }
            }
            if inputOpen, fds[2].revents != 0 {
                let n = credential.withUnsafeBytes { Darwin.write(fds[2].fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                if n > 0 { offset += n }
                else if n < 0 && errno != EINTR && errno != EAGAIN { fail(.output) }
                if offset == credential.count { try? input.fileHandleForWriting.close(); inputOpen = false }
            }
            if exit.hasExited {
                if exitAt == nil { exitAt = now }
                // Descendants holding pipes do not extend a successful response.
                if open.contains(true) && now - exitAt! < 1_000_000_000 { continue }
                if open.contains(true) { fail(.output) }
                if child.terminationReason != .exit || child.terminationStatus != 0 { fail(.childFailed) }
                if data.last != 10 || data.count <= 1 || data.filter({ $0 == 10 }).count != 1 { fail(.output) }
                let payload = Data(data.dropLast())
                if (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] == nil { fail(.output) }
                if offset != credential.count { fail(.output) }
                condition.lock(); bytes = failure == nil ? payload : nil
                observed = true; completed = true; condition.broadcast(); condition.unlock()
                return
            }
        }
    }
}
