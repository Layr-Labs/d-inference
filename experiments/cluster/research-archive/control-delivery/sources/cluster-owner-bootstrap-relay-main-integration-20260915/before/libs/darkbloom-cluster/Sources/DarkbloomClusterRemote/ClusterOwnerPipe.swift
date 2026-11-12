import Foundation
import Darwin
import DarkbloomClusterProtocol

/// Dedicated owned stdio, with independent read and write callers. Every wait is
/// bounded; no user callback runs under its writer lock or on its reader.
final class ClusterOwnerPipe: @unchecked Sendable {
    let input: Int32
    let output: Int32
    private let writing = NSLock()
    private var decoder: ClusterWorkerLineDecoder
    private var pending: [Data] = []
    private var outputClosed = false
    init(input: Int32, output: Int32, readingCommands: Bool) throws {
        let i = fcntl(input, F_DUPFD_CLOEXEC, 3), o = fcntl(output, F_DUPFD_CLOEXEC, 3)
        guard i >= 0, o >= 0 else { if i >= 0 { Darwin.close(i) }; if o >= 0 { Darwin.close(o) }; throw OwnerWire.invalid("Cannot own owner pipes") }
        self.input = i; self.output = o; decoder = .init(commandStream: readingCommands)
        for fd in [i, o] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                Darwin.close(i); Darwin.close(o); throw OwnerWire.invalid("Cannot bound owner IO")
            }
        }
        guard fcntl(o, F_SETNOSIGPIPE, 1) == 0 else { Darwin.close(i); Darwin.close(o); throw OwnerWire.invalid("Cannot suppress owner SIGPIPE") }
    }
    /// Nil means no complete line before this short poll deadline; EOF throws.
    func read(until deadline: UInt64) throws -> Data? {
        if !pending.isEmpty { return pending.removeFirst() }
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var p = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let n = Darwin.poll(&p, 1, 20)
            if n < 0 { if errno == EINTR { continue }; throw ClusterWorkerOwnerErrorProxy.closed }
            if n == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 { try decoder.finish(); throw ClusterWorkerOwnerErrorProxy.closed }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw ClusterWorkerOwnerErrorProxy.closed }
            pending += try decoder.append(Data(buffer.prefix(count)))
            guard pending.count <= 32 else { throw OwnerWire.invalid("Owner input queue exceeded bound") }
            if !pending.isEmpty { return pending.removeFirst() }
        }
        return nil
    }
    func write(_ bytes: Data, until deadline: UInt64) throws {
        try writing.withLock {
            guard !outputClosed else { throw ClusterWorkerOwnerErrorProxy.closed }
            var offset = 0
            while offset < bytes.count {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ClusterWorkerOwnerErrorProxy.deadline }
                var p = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                let n = Darwin.poll(&p, 1, 20)
                if n < 0 { if errno == EINTR { continue }; throw ClusterWorkerOwnerErrorProxy.closed }
                if n == 0 { continue }
                let count = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset)) }
                if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw ClusterWorkerOwnerErrorProxy.closed }
                guard count > 0 else { throw ClusterWorkerOwnerErrorProxy.closed }; offset += count
            }
        }
    }
    func closeOutput() { writing.withLock { if !outputClosed { outputClosed = true; Darwin.close(output) } } }
    deinit { Darwin.close(input); if !outputClosed { Darwin.close(output) } }
}
