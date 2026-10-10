import Foundation
import Darwin

/// Process signals belong to the CLI. Install before starting native owners;
/// a signal arriving before the serving task is attached remains latched.
final class DistributedStartSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    // SIG_DFL is represented by a null function pointer on Darwin.
    private var previous: [(Int32, sig_t?)] = []
    private var action: (@Sendable () -> Void)?
    private var terminated = false
    private var closed = false

    private enum SetupError: Error { case registrationTimedOut }

    init() throws {
        for number in [SIGTERM, SIGINT] {
            previous.append((number, signal(number, SIG_IGN)))
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
        let values = lock.withLock { () -> ([DispatchSourceSignal], [(Int32, sig_t?)]) in
            guard !closed else { return ([], []) }
            closed = true; action = nil
            let result = (sources, previous)
            sources.removeAll(); previous.removeAll()
            return result
        }
        values.0.forEach { $0.cancel() }
        for (number, handler) in values.1 { signal(number, handler) }
    }

    deinit { close() }
}
