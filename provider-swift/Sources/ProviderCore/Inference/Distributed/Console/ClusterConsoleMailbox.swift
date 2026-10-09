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

/// Window-size changes and requests to end, delivered as mail instead of as
/// handlers. Installed only while a screen is open, and undone when it closes.
final class ClusterConsoleSignals: @unchecked Sendable {
    private var sources = [DispatchSourceSignal]()
    /// What each signal did before, restored whole: handler, mask and flags.
    private var previous: [(number: Int32, action: Darwin.sigaction)] = []

    init(mailbox: ClusterConsoleMailbox) {
        for number in [SIGINT, SIGTERM, SIGHUP, SIGWINCH] {
            // A dispatch source only sees a signal whose default action is off.
            var ignore = Darwin.sigaction(), earlier = Darwin.sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            guard sigaction(number, &ignore, &earlier) == 0 else { continue }
            previous.append((number, earlier))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                mailbox.post(number == SIGWINCH ? .windowChanged : .event(.terminationSignal(number)))
            }
            source.resume()
            sources.append(source)
        }
    }

    func close() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for (number, action) in previous {
            var earlier = action
            sigaction(number, &earlier, nil)
        }
        previous.removeAll()
    }

    deinit { close() }
}
