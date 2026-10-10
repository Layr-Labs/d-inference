import Darwin
import DarkbloomClusterProtocol
import Foundation

/// One control reader and one native-executor writer. No Foundation pipe read
/// that waits to fill a buffer, unbounded line, or resettable request deadline.
final class WorkerPipes: @unchecked Sendable {
    let input: Int32, output: Int32, deadline: UInt64
    private let inputFlags: Int32, outputFlags: Int32
    private var inputBytes = 0, outputBytes = 0
    private static let maximumInputBytes = 32 * 1024 * 1024
    private static let maximumOutputBytes = 8 * 1024 * 1024

    init(input: Int32, output: Int32, deadline: UInt64) throws {
        self.input = input; self.output = output; self.deadline = deadline
        inputFlags = fcntl(input, F_GETFL); outputFlags = fcntl(output, F_GETFL)
        guard inputFlags >= 0, outputFlags >= 0 else { throw WorkerFailure.invalid("Worker pipe descriptors are unavailable") }
        guard fcntl(input, F_SETFL, inputFlags | O_NONBLOCK) == 0 else { throw WorkerFailure.invalid("Cannot configure worker input") }
        guard fcntl(output, F_SETFL, outputFlags | O_NONBLOCK) == 0 else {
            _ = fcntl(input, F_SETFL, inputFlags)
            throw WorkerFailure.invalid("Cannot configure worker output")
        }
    }

    func check() throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw WorkerFailure.invalid("Worker absolute lifetime expired") }
    }

    func requireNoEarlyInput() throws {
        var value = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        let count = poll(&value, 1, 0)
        guard count == 0 else { throw WorkerFailure.invalid("Input or EOF arrived before worker readiness") }
    }

    /// nil is a poll tick; empty Data is actual EOF.
    func readChunk() throws -> Data? {
        try check()
        var value = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        let count = poll(&value, 1, 100)
        if count < 0 && errno == EINTR { return nil }
        guard count >= 0, value.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw WorkerFailure.invalid("Worker input poll failed") }
        guard count > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: ClusterWorkerLineDecoder.readChunkBytes)
        let received = bytes.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
        if received < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { return nil }
        guard received >= 0, received <= Self.maximumInputBytes - inputBytes else { throw WorkerFailure.invalid("Worker input failed or exceeded total byte bound") }
        inputBytes += received
        return Data(bytes.prefix(received))
    }

    func write(_ data: Data, requestDeadline: UInt64? = nil) throws {
        guard data.count <= ClusterWorkerLimits.eventBytes, data.count <= Self.maximumOutputBytes - outputBytes else {
            throw WorkerFailure.invalid("Worker output exceeded bounded event/total bytes")
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try check()
                if let requestDeadline, DispatchTime.now().uptimeNanoseconds >= requestDeadline {
                    throw WorkerFailure.invalid("Worker output exceeded its request deadline")
                }
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && [EAGAIN, EWOULDBLOCK].contains(errno) else { throw WorkerFailure.invalid("Worker output write failed") }
                var value = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&value, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0, value.revents & Int16(POLLNVAL | POLLERR | POLLHUP) == 0 else { throw WorkerFailure.invalid("Worker output poll failed") }
            }
        }
        outputBytes += data.count
    }

    deinit {
        _ = fcntl(input, F_SETFL, inputFlags)
        _ = fcntl(output, F_SETFL, outputFlags)
    }
}
