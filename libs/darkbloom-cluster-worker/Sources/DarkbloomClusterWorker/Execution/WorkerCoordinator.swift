import DarkbloomClusterProtocol
import Foundation

/// The main process thread is the dedicated synchronous native executor. The
/// reader only validates control, queues one next action, and signals cancel.
/// All protocol state and event publication share the condition lock; a failed
/// write never advances the published event sequence or authorizes more work.
final class WorkerCoordinator: @unchecked Sendable {
    private let runtime: any WorkerRuntime
    private let pipes: WorkerPipes
    private let ready: ClusterWorkerReady
    private let condition = NSCondition()
    private let readerDone = DispatchGroup()
    private var session: ClusterWorkerSession
    private var eventSequence: UInt64 = 0
    private var actions: [ClusterWorkerCommandFrame] = []
    private var decision: ClusterWorkerTokenDecision?
    private var failure: Error?
    private var stopped = false
    private var shutdownReceived = false
    private var requestDeadline: UInt64?

    init(runtime: any WorkerRuntime, pipes: WorkerPipes) throws {
        guard let ready = runtime.readiness else { throw WorkerFailure.invalid("Native owner did not establish bilateral readiness") }
        self.runtime = runtime; self.pipes = pipes; self.ready = ready
        session = try .init(identity: ready.identity, rank: ready.rank, profile: ready.profile,
            executionPlanSHA256: ready.executionPlanSHA256)
    }

    func run() throws {
        var readerStarted = false
        var modelReleased = false
        defer {
            condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
            if readerStarted { _ = readerDone.wait(timeout: .now() + 2) }
        }
        do {
            try pipes.requireNoEarlyInput()
            try publish(.ready(ready), requestID: nil)
            readerDone.enter(); readerStarted = true
            Thread.detachNewThread { [self] in
                defer { readerDone.leave() }
                do { try readControl() } catch { fail(error) }
            }
            while true {
                let command = try nextAction()
                switch command.command {
                case .reserve(let value):
                    do {
                        let bytes = try runtime.reserve(command.requestID!, value)
                        try publish(.admitted(reservedBytes: bytes), requestID: command.requestID)
                    } catch {
                        let available = runtime.readiness != nil
                        try publish(.refused(available ? .unsupported : .unavailable), requestID: command.requestID)
                        if !available { throw error }
                    }
                case .start:
                    let id = command.requestID!
                    let reason = try runtime.start(id) { ordinal, token, frontier in
                        try self.publish(.committedToken(ordinal: ordinal, tokenID: token, committedTokens: frontier), requestID: id)
                        return try self.nextDecision() == .proceed
                    }
                    // The native facade returns only after bilateral retirement
                    // and after its request/autorelease scope has ended.
                    try publish(.finished(reason), requestID: id)
                    try publish(.retired(.clean), requestID: id)
                    if runtime.readiness == nil { try publish(.unavailable(.runtimeError), requestID: nil) }
                case .shutdown:
                    try runtime.shutdown()
                    modelReleased = true
                    try publish(.shutdownComplete, requestID: nil)
                    return
                case .cancel:
                    throw WorkerFailure.invalid("Request cancelled before native start or after its return")
                case .tokenDecision:
                    throw WorkerFailure.invalid("Token decision escaped its callback credit")
                }
            }
        } catch {
            let primary = error
            let id = activeRequest()
            if let id {
                runtime.cancel(id)
                // A protocol/pipe failure may make this publication impossible.
                // Never invent retired merely because native start threw.
                try? publish(.failed(.runtimeError), requestID: id)
            }
            if !modelReleased {
                do { try runtime.shutdown() }
                catch { throw WorkerFailure.invalid("Worker failed (\(primary)); local cleanup failed (\(error))") }
            }
            throw primary
        }
    }

    private func publish(_ event: ClusterWorkerEvent, requestID: UUID?) throws {
        condition.lock(); defer { condition.unlock() }
        if let failure { throw failure }
        let frame = ClusterWorkerEventFrame(membershipEpoch: ready.identity.membershipEpoch,
            sequence: eventSequence, requestID: requestID, event: event)
        var proposed = session
        do {
            try proposed.accept(frame, now: DispatchTime.now().uptimeNanoseconds)
            try pipes.write(ClusterWorkerCodec.encode(frame), requestDeadline: requestDeadline)
            session = proposed; eventSequence += 1
            switch event {
            case .refused, .retired: requestDeadline = nil
            default: break
            }
        } catch { failure = error; condition.broadcast(); throw error }
    }

    private func readControl() throws {
        var decoder = ClusterWorkerLineDecoder(commandStream: true)
        while true {
            condition.lock(); let done = stopped; let deadline = requestDeadline; condition.unlock()
            if done { return }
            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline {
                throw WorkerFailure.invalid("Worker request deadline expired while awaiting control")
            }
            guard let chunk = try pipes.readChunk() else { continue }
            if chunk.isEmpty {
                try decoder.finish()
                condition.lock(); let normal = shutdownReceived || stopped; condition.unlock()
                guard normal else { throw WorkerFailure.invalid("EOF preceded explicit worker shutdown") }
                return
            }
            let frames = try decoder.append(chunk).map(ClusterWorkerCodec.decodeCommand)
            condition.lock()
            do {
                // Validate every already-read command before waking the native
                // executor: start+early tokenDecision in one pipe read cannot
                // borrow the token credit created while parsing that batch.
                for frame in frames {
                    if let failure { throw failure }
                    guard !stopped else { throw WorkerFailure.invalid("Control after worker stop") }
                    try session.accept(frame, now: DispatchTime.now().uptimeNanoseconds)
                    switch frame.command {
                    case .reserve(let value):
                        requestDeadline = value.deadlineUptimeNanoseconds
                        guard actions.isEmpty else { throw WorkerFailure.invalid("Reservation overlaps a pending action") }
                        actions.append(frame)
                    case .tokenDecision(_, let value): decision = value
                    case .cancel:
                        // This method touches only the facade's locked flag.
                        runtime.cancel(frame.requestID!)
                        guard actions.count < 2 else { throw WorkerFailure.invalid("Worker action queue exceeded its bound") }
                        actions.append(frame)
                    case .shutdown:
                        shutdownReceived = true
                        guard actions.isEmpty else { throw WorkerFailure.invalid("Shutdown overlaps a pending action") }
                        actions.append(frame)
                    default:
                        guard actions.isEmpty else { throw WorkerFailure.invalid("Worker received an overlapping action") }
                        actions.append(frame)
                    }
                }
                condition.broadcast(); condition.unlock()
            } catch { condition.unlock(); throw error }
        }
    }

    private func nextAction() throws -> ClusterWorkerCommandFrame {
        condition.lock(); defer { condition.unlock() }
        while actions.isEmpty && failure == nil { condition.wait() }
        if let failure { throw failure }
        return actions.removeFirst()
    }

    private func nextDecision() throws -> ClusterWorkerTokenDecision {
        condition.lock(); defer { condition.unlock() }
        while decision == nil && failure == nil && actions.isEmpty { condition.wait() }
        if let failure { throw failure }
        guard actions.isEmpty, let value = decision else { throw WorkerFailure.invalid("Token decision interrupted by cancellation") }
        decision = nil
        return value
    }

    private func activeRequest() -> UUID? {
        condition.lock(); defer { condition.unlock() }; return session.activeRequestID
    }

    private func fail(_ error: Error) {
        condition.lock()
        failure = failure ?? error
        let id = session.activeRequestID
        condition.broadcast(); condition.unlock()
        if let id { runtime.cancel(id) }
    }
}
