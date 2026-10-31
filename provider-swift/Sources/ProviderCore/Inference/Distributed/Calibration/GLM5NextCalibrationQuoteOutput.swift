import Darwin
import Foundation

/// Finite JSONL output for the private installed quotation command.
public enum GLM5NextCalibrationQuoteOutput {
    enum Failure: Error { case invalid, deadline, output }

    public static func write(_ response: Data, descriptor: Int32 = STDOUT_FILENO, deadline: UInt64) throws {
        guard !response.isEmpty, response.count <= 65_536,
              !response.contains(10), !response.contains(13) else { throw Failure.invalid }
        try check(deadline)
        let flags = fcntl(descriptor, F_GETFL), noSignal = fcntl(descriptor, F_GETNOSIGPIPE)
        guard flags >= 0, noSignal >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.output
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.output }
        defer { _ = fcntl(descriptor, F_SETNOSIGPIPE, noSignal) }
        let bytes = response + Data([10])
        var offset = 0
        while offset < bytes.count {
            try check(deadline)
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count > 0 { offset += count; continue }
            if count < 0 && errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw Failure.output }
            let remaining = deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)
            var output = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&output, 1, Int32(min(20, remaining / 1_000_000)))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0, output.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw Failure.output }
        }
        try check(deadline)
    }

    private static func check(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.deadline }
    }
}
