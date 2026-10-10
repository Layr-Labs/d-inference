import Foundation
import Darwin

/// Window-size changes and requests to end, delivered as mail instead of as
/// handlers. Installed only while a screen is open, and undone when it closes.
///
/// A request to end is an event for the run loop, which restores the terminal
/// and stops a session it started. A second request means the loop did not get
/// to the first, so `stuck` runs instead and must end the process itself.
final class ClusterConsoleSignals: @unchecked Sendable {
    private static let registrationAllowanceSeconds = 2.0
    private static let ending = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]

    private let lock = NSLock()
    private var sources = [DispatchSourceSignal]()
    /// What each signal did before, restored whole: handler, mask and flags.
    private var previous: [(number: Int32, action: Darwin.sigaction)] = []
    private var endRequested = false

    init(mailbox: ClusterConsoleMailbox, stuck: @escaping @Sendable (Int32) -> Void) {
        for number in Self.ending + [SIGWINCH] {
            // A dispatch source only sees a signal whose default action is off.
            var ignore = Darwin.sigaction(), earlier = Darwin.sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            guard sigaction(number, &ignore, &earlier) == 0 else { continue }
            previous.append((number, earlier))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            // Until the source is registered a signal would be dropped, not delivered.
            let registered = DispatchSemaphore(value: 0)
            source.setRegistrationHandler { registered.signal() }
            source.setEventHandler { [weak self] in
                guard number != SIGWINCH else { return mailbox.post(.windowChanged) }
                guard let self else { return }
                let again = self.lock.withLock { () -> Bool in
                    defer { self.endRequested = true }
                    return self.endRequested
                }
                if again { stuck(number) } else { mailbox.post(.event(.terminationSignal(number))) }
            }
            source.resume()
            _ = registered.wait(timeout: .now() + Self.registrationAllowanceSeconds)
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
