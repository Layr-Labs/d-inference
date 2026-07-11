import Dispatch
import Foundation
import Darwin

final class FanTerminationMonitor: @unchecked Sendable {
    private let stateLock = NSLock()
    private let wakeup = DispatchSemaphore(value: 0)
    private var terminationRequested = false
    private var sources: [DispatchSourceSignal] = []

    init() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                self?.requestTermination()
            }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
    }

    var isTerminationRequested: Bool {
        stateLock.withLock { terminationRequested }
    }

    func wait(for interval: TimeInterval) -> Bool {
        if isTerminationRequested {
            return true
        }
        _ = wakeup.wait(timeout: .now() + interval)
        return isTerminationRequested
    }

    private func requestTermination() {
        let shouldWake = stateLock.withLock {
            guard !terminationRequested else { return false }
            terminationRequested = true
            return true
        }
        if shouldWake {
            wakeup.signal()
        }
    }
}
