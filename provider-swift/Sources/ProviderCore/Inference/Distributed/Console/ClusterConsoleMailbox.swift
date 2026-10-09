import Foundation
import Darwin

/// How work running elsewhere reaches the run loop's thread: results are
/// queued here and one byte on a pipe wakes the loop's `poll`.
final class ClusterConsoleMailbox: @unchecked Sendable {
    enum Mail: Sendable {
        case event(ClusterConsoleEvent)
        /// SIGWINCH: the loop asks the terminal for its new size.
        case windowChanged
    }

    let readEnd: Int32
    private let writeEnd: Int32
    private let lock = NSLock()
    private var mail = [Mail]()
    private var closed = false

    init() throws {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw ClusterConsoleTerminal.Failure.cannotConfigure(errno) }
        for end in ends {
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        readEnd = ends[0]; writeEnd = ends[1]
    }

    func post(_ item: Mail) {
        lock.withLock {
            guard !closed else { return }
            mail.append(item)
            var byte: UInt8 = 1
            // A full pipe already holds a wake-up.
            _ = Darwin.write(writeEnd, &byte, 1)
        }
    }

    func post(_ event: ClusterConsoleEvent) { post(.event(event)) }

    func take() -> [Mail] {
        var buffer = [UInt8](repeating: 0, count: 256)
        while Darwin.read(readEnd, &buffer, buffer.count) > 0 {}
        return lock.withLock {
            defer { mail.removeAll() }
            return mail
        }
    }

    /// Later posts are dropped: the loop that would read them is gone.
    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(readEnd)
            Darwin.close(writeEnd)
        }
    }

    deinit { close() }
}
