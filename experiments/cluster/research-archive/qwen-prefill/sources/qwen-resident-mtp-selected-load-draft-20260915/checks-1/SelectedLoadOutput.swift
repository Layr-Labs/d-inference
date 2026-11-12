import Darwin
import Foundation

/// Two bounded JSON lines only. A full stdout pipe cannot extend the absolute
/// process lifetime. This is benchmark output, not the serving worker protocol.
final class SelectedLoadOutput {
    private let descriptor: Int32
    private let deadline: UInt64
    private var count = 0

    init(descriptor: Int32, deadline: UInt64) throws {
        self.descriptor = descriptor; self.deadline = deadline
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw WorkerFailure.invalid("Cannot bound loading-check output")
        }
    }

    func write(_ bytes: Data) throws {
        guard count < 2, !bytes.isEmpty, bytes.count <= 8_388_608,
              !bytes.contains(10), !bytes.contains(13) else {
            throw WorkerFailure.invalid("Loading-check record count, framing or size differs")
        }
        var line = bytes; line.append(10)
        var offset = 0
        while offset < line.count {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw WorkerFailure.invalid("Loading-check output deadline exceeded") }
            let wrote = line.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if wrote > 0 { offset += wrote; continue }
            if wrote < 0 && errno == EINTR { continue }
            guard wrote < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                throw WorkerFailure.invalid("Loading-check output failed")
            }
            var descriptor = pollfd(fd: self.descriptor, events: Int16(POLLOUT), revents: 0)
            let wait = Int32(min(UInt64(100), (deadline - now + 999_999) / 1_000_000))
            let ready = poll(&descriptor, 1, wait)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0, descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                throw WorkerFailure.invalid("Loading-check output pipe closed")
            }
        }
        count += 1
    }
}
