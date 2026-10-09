import Foundation
import Darwin

/// Process signals belong to the CLI. Install before starting native owners;
/// a signal arriving before the serving task is attached remains latched.
final class DistributedStartSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var previous: [SavedDisposition] = []
    private var action: (@Sendable () -> Void)?
    private var terminated = false
    private var closed = false

    private enum SetupError: Error { case registrationTimedOut }

    /// What a signal did before this object ignored it: handler, flags and
    /// blocked signals, as `sigaction` reports them, so `close()` puts back
    /// exactly that. The handler is not kept as a Swift function pointer:
    /// `SIG_IGN` is the address 1, which Swift also uses for `nil` in an
    /// optional pair that holds one, so a loop over such pairs ends at the
    /// first ignored signal and restores nothing after it.
    private struct SavedDisposition {
        let number: Int32
        var action: sigaction
    }

    init() throws {
        for number in [SIGTERM, SIGINT] {
            var ignore = sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            var earlier = sigaction()
            if sigaction(number, &ignore, &earlier) == 0 {
                previous.append(SavedDisposition(number: number, action: earlier))
            }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            let registered = DispatchSemaphore(value: 0)
            source.setRegistrationHandler { registered.signal() }
            source.setEventHandler { [weak self] in self?.receivedTermination() }
            sources.append(source)
            source.resume()
            guard registered.wait(timeout: .now() + 2) == .success else {
                throw SetupError.registrationTimedOut
            }
        }
    }

    func attach(_ action: @escaping @Sendable () -> Void) {
        let invoke = lock.withLock { () -> Bool in
            guard !closed else { return false }
            self.action = action
            return terminated
        }
        if invoke { action() }
    }

    private func receivedTermination() {
        let value = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !closed, !terminated else { return nil }
            terminated = true
            return action
        }
        value?()
    }

    func close() {
        let values = lock.withLock { () -> ([DispatchSourceSignal], [SavedDisposition]) in
            guard !closed else { return ([], []) }
            closed = true; action = nil
            let result = (sources, previous)
            sources.removeAll(); previous.removeAll()
            return result
        }
        values.0.forEach { $0.cancel() }
        for var saved in values.1 { sigaction(saved.number, &saved.action, nil) }
    }

    deinit { close() }
}
