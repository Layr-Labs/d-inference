import Darwin
import Foundation

/// While a hidden read waits with the terminal's echo off, a signal that would end the command (^C, ^\, a hang-up or
/// `kill`) puts the terminal back first, then ends the command as it would have. A signal the command already
/// ignores stays ignored.
///
/// The signals are ignored and watched with dispatch sources (as `DistributedStartSignals` does), so the terminal is
/// put back outside a signal handler; `close()` puts back exactly what each signal did before.
final class HiddenReadSignals: @unchecked Sendable {
    private let lock = NSLock()
    private let restore: @Sendable () -> Void
    private var restored = false
    private var sources: [DispatchSourceSignal] = []
    private var previous: [(number: Int32, action: sigaction)] = []

    /// - Parameters:
    ///   - restore: puts the terminal back; runs once, on `close()` or on the first signal.
    ///   - onSignal: runs after `restore`, with the signal's own handling back.
    init(restore: @escaping @Sendable () -> Void, onSignal: @escaping @Sendable (Int32) -> Void) {
        self.restore = restore
        for number in [SIGINT, SIGQUIT, SIGHUP, SIGTERM] {
            var ignore = sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            var earlier = sigaction()
            guard sigaction(number, &ignore, &earlier) == 0 else { continue }
            previous.append((number, earlier))
            // `SIG_IGN` is the address 1, so the handler is read as a number.
            guard withUnsafeBytes(of: earlier.__sigaction_u, { $0.load(as: UInt.self) }) != 1 else { continue }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            let registered = DispatchSemaphore(value: 0)
            source.setRegistrationHandler { registered.signal() }
            source.setEventHandler { [weak self] in self?.received(number, onSignal: onSignal) }
            sources.append(source)
            source.resume()
            _ = registered.wait(timeout: .now() + 2)
        }
    }

    /// The read ended: the terminal back, then the signals.
    func close() {
        restoreOnce()
        putSignalsBack()
    }

    private func received(_ number: Int32, onSignal: @Sendable (Int32) -> Void) {
        guard restoreOnce() else { return }
        putSignalsBack()
        onSignal(number)
    }

    /// Under the lock, so the terminal is never touched once `close()` has returned and its descriptor may be closed.
    @discardableResult
    private func restoreOnce() -> Bool {
        lock.withLock {
            guard !restored else { return false }
            restored = true
            restore()
            return true
        }
    }

    private func putSignalsBack() {
        let (sources, previous) = lock.withLock {
            defer { self.sources.removeAll(); self.previous.removeAll() }
            return (self.sources, self.previous)
        }
        sources.forEach { $0.cancel() }
        for (number, action) in previous {
            var action = action
            sigaction(number, &action, nil)
        }
    }

    deinit { close() }
}
