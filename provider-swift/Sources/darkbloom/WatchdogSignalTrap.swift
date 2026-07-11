import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum WatchdogSignalTrap {
    static func waitForTermination() async {
        #if canImport(Darwin)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        await withCheckedContinuation { continuation in
            let state = ResumeOnce(continuation)
            let term = DispatchSource.makeSignalSource(
                signal: SIGTERM,
                queue: .global(qos: .utility)
            )
            let interrupt = DispatchSource.makeSignalSource(
                signal: SIGINT,
                queue: .global(qos: .utility)
            )
            term.setEventHandler { state.resume() }
            interrupt.setEventHandler { state.resume() }
            term.resume()
            interrupt.resume()
            state.retain(term, interrupt)
        }
        #else
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
        }
        #endif
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var sources: [DispatchSourceSignal] = []

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func retain(_ sources: DispatchSourceSignal...) {
            lock.withLock {
                self.sources = sources
            }
        }

        func resume() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                let pending = continuation
                continuation = nil
                sources.forEach { $0.cancel() }
                sources.removeAll()
                return pending
            }
            pending?.resume()
        }
    }
}
