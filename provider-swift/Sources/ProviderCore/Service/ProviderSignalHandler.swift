import Dispatch
import Foundation
import Darwin

/// Retained for the serve process lifetime. Signal delivery only schedules the
/// shared async drain; it never cancels the running serve task.
public final class ProviderSignalHandler: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []

    public init(onTermination: @escaping @Sendable () async -> Void) {
        for signo in ProviderStopSignals.forCurrentProcess() {
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .global(qos: .utility))
            source.setEventHandler { Task { await onTermination() } }
            source.resume()
            sources.append(source)
        }
    }

    deinit { for source in sources { source.cancel() } }
}

/// Red control: declared so the new tests compile. The base's handler doesn't
/// use it, and every signal drains.
struct ProviderStopSignalState {
    enum Action: Equatable { case drain, exitNow }
    static let interruptedStatus: Int32 = 128 + SIGINT
    mutating func receive(_ signo: Int32) -> Action { .drain }
}
