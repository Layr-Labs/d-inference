import Darwin
import Foundation

/// SIGINT/SIGTERM and listener failures become one shutdown request. The first
/// request cancels a load in progress or starts drain; a second signal exits
/// immediately and is logged as unverified retirement.
actor RunnerShutdown {
    enum Reason: Sendable {
        case signal(Int32)
        case failure(String)

        var json: RunnerJSON {
            switch self {
            case .signal(let number): ["signal": .int(Int64(number))]
            case .failure(let reason): ["failure": .string(reason)]
            }
        }
    }

    private let log: RunnerEventLog
    private var reason: Reason?
    private var signals = 0
    private var waiters: [CheckedContinuation<Reason, Never>] = []
    private var cancelLoad: (@Sendable () -> Void)?
    private var signalSources: [any DispatchSourceSignal] = []

    init(log: RunnerEventLog) { self.log = log }

    func installSignalHandlers() {
        let queue = DispatchQueue(label: "nemotron-super-runner.signals")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                Task { await self?.request(.signal(number)) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func setLoadCancellation(_ cancel: (@Sendable () -> Void)?) { cancelLoad = cancel }

    var requested: Bool { reason != nil }

    func request(_ next: Reason) {
        if case .signal = next {
            signals += 1
            if signals > 1 {
                log.emit("runner.forced_exit", next.json.merging(["retirement": "unverified"]).asFields)
                // _exit: no atexit handlers or static destructors while GPU work may be live.
                _exit(EXIT_FAILURE)
            }
        }
        guard reason == nil else { return }
        reason = next
        log.emit("shutdown.requested", next.json.asFields)
        cancelLoad?()
        for waiter in waiters { waiter.resume(returning: next) }
        waiters = []
    }

    func wait() async -> Reason {
        if let reason { return reason }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

extension RunnerJSON {
    var asFields: [String: RunnerJSON] {
        if case .object(let fields) = self { return fields }
        return [:]
    }
}
