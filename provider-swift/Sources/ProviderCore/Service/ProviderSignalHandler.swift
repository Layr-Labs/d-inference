import Dispatch
import Foundation
import Darwin

/// Retained for the serve process lifetime. Signal delivery only schedules the
/// shared async drain; it never cancels the running serve task.
public final class ProviderSignalHandler: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []

    public init(onTermination: @escaping @Sendable () async -> Void) {
        for signo in [SIGTERM, SIGINT] {
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .global(qos: .utility))
            source.setEventHandler { Task { await onTermination() } }
            source.resume()
            sources.append(source)
        }
    }

    deinit { for source in sources { source.cancel() } }
}
