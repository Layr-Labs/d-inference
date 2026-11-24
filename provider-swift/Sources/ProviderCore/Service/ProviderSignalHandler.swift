import Dispatch
import Foundation
import Darwin

/// Retained for the serve process lifetime. Signal delivery only schedules the
/// shared async drain; it never cancels the running serve task. A second
/// Ctrl-C during that drain ends the process at once (`ProviderStopSignalState`).
public final class ProviderSignalHandler: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var state = ProviderStopSignalState()

    public init(onTermination: @escaping @Sendable () async -> Void) {
        for signo in ProviderStopSignals.forCurrentProcess() {
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .global(qos: .utility))
            // A source merges deliveries that arrive before its handler runs;
            // `data` counts them, so two quick Ctrl-Cs are still two. The
            // handler holds its source until `deinit` cancels it.
            source.setEventHandler { [weak self] in
                for _ in 0 ..< max(1, Int(source.data)) {
                    guard let self else { return }
                    switch self.lock.withLock({ self.state.receive(signo) }) {
                    case .drain:
                        Task { await onTermination() }
                    case .exitNow:
                        ProviderStopSignalState.exitWithoutDraining()
                    }
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    deinit { for source in sources { source.cancel() } }
}

/// What each stop signal does. The first one, and every SIGTERM or SIGHUP,
/// asks for the drain (`ProviderTermination.request`, which runs it once).
/// A SIGINT after any stop signal is a second Ctrl-C at the terminal: the
/// process exits at once, without finishing the drain. SIGTERM never does,
/// because the cluster supervisor and launchd may send it more than once.
struct ProviderStopSignalState {
    enum Action: Equatable { case drain, exitNow }

    /// 128 + SIGINT, the status a shell reports for an interrupted process.
    static let interruptedStatus: Int32 = 128 + SIGINT

    private var stopping = false

    mutating func receive(_ signo: Int32) -> Action {
        if signo == SIGINT, stopping { return .exitNow }
        stopping = true
        return .drain
    }

    static func exitWithoutDraining() -> Never {
        let line = "Second Ctrl-C: exiting now, without finishing the drain\n"
        _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
        _exit(interruptedStatus)
    }
}
