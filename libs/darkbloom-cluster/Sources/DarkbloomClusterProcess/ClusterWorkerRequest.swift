import Foundation
import DarkbloomClusterProtocol

public final class ClusterWorkerRequest: @unchecked Sendable {
    public let requestID: UUID
    public let reservation: ClusterWorkerReservation
    private let owner: ClusterWorkerPair
    private let lock = NSLock()
    private let retired = WorkerCompletion()
    private let queue = DispatchQueue(label: "darkbloom.worker.request")
    private var started = false
    private var admitted = false
    private var admitting = true
    private var released = false
    private var cancellation: ClusterWorkerCancellationReason?
    private var byteReservation = 0
    private enum Submission { case none, submitted, admitted, refused }
    private var submissions: [Submission] = [.none, .none]
    private var callback: (@Sendable (ClusterWorkerRequestEvent) -> Bool)?
    public var reservedBytes: Int { lock.withLock { byteReservation } }
    public var bytesInUse: Int { lock.withLock { released ? 0 : byteReservation } }
    public var isRetired: Bool { retired.isComplete }
    private var isCancelled: Bool { lock.withLock { cancellation != nil } }

    init(owner: ClusterWorkerPair, requestID: UUID, reservation: ClusterWorkerReservation) {
        self.owner = owner; self.requestID = requestID; self.reservation = reservation
        byteReservation = reservation.capacityLimitBytes
    }

    func admit(until admissionDeadline: UInt64? = nil) throws {
        defer {
            let cleanup = lock.withLock { () -> Bool in
                admitting = false
                if cancellation != nil && !started { started = true; return true }; return false
            }
            if cleanup { queue.async { self.cleanup(acknowledged: [false, false]) } }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < reservation.deadlineUptimeNanoseconds,
              reservation.deadlineUptimeNanoseconds - now <= ClusterWorkerLimits.deadlineNanoseconds else {
            throw ClusterWorkerOwnerError.deadline
        }
        let deadline = min(reservation.deadlineUptimeNanoseconds, admissionDeadline ?? UInt64.max,
                           now + 5_000_000_000)
        guard now < deadline else { throw ClusterWorkerOwnerError.deadline }
        var bytes = 0
        for (index, worker) in owner.workers.enumerated() {
            guard let capacity = worker.readiness?.requestCapacityBytes,
                  bytes < reservation.capacityLimitBytes else { throw ClusterWorkerOwnerError.unavailable }
            let local = ClusterWorkerReservation(profileID: reservation.profileID, promptTokenIDs: reservation.promptTokenIDs,
                stopTokenIDs: reservation.stopTokenIDs, outputCount: reservation.outputCount, chunkSize: reservation.chunkSize,
                deadlineUptimeNanoseconds: reservation.deadlineUptimeNanoseconds,
                capacityLimitBytes: min(capacity, reservation.capacityLimitBytes - bytes))
            try lock.withLock {
                guard cancellation == nil else { throw ClusterWorkerOwnerError.cancelled }
                try worker.sendWorkerCommand(.reserve(local), requestID: requestID, deadline: deadline)
                submissions[index] = .submitted
            }
            let event = try worker.receiveWorkerEvent(until: deadline, cancelled: { self.isCancelled })
            guard event.requestID == requestID else { throw ClusterWorkerOwnerError.unavailable }
            if case .refused = event.event {
                lock.withLock { submissions[index] = .refused }
                throw ClusterWorkerOwnerError.unavailable
            }
            guard case .admitted(let allocation) = event.event,
                  allocation <= local.capacityLimitBytes, allocation <= capacity else {
                throw ClusterWorkerOwnerError.unavailable
            }
            lock.withLock { submissions[index] = .admitted }
            bytes += allocation // Bounded by the remaining global ceiling above.
        }
        try lock.withLock {
            guard cancellation == nil else { throw ClusterWorkerOwnerError.cancelled }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ClusterWorkerOwnerError.deadline }
            byteReservation = bytes; admitted = true
        }
        DispatchQueue.global().asyncAfter(deadline: .init(uptimeNanoseconds: reservation.deadlineUptimeNanoseconds)) { [weak self] in
            if let self, !self.retired.isComplete { self.cancel(reason: .deadline) }
        }
    }

    public func start(emit: @escaping @Sendable (ClusterWorkerRequestEvent) -> Bool) throws {
        try lock.withLock {
            guard admitted && !started && cancellation == nil && !released else { throw ClusterWorkerOwnerError.unavailable }
            callback = emit; started = true
        }
        queue.async { self.run() }
    }

    public func cancel(reason: ClusterWorkerCancellationReason = .callerCancelled) {
        let action = lock.withLock { () -> (run: Bool, first: Bool) in
            if retired.isComplete { return (false, false) }
            let first = cancellation == nil
            cancellation = cancellation ?? reason
            if started || admitting { return (false, first) }; started = true; return (true, first)
        }
        if action.run { queue.async { self.cleanup(acknowledged: [false, false]) } }
        guard action.first else { return }
        // Cancellation cannot rely on a responsive callback or native receive.
        // The watchdog is independent of the request queue and observes real exit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.retired.isComplete else { return }
            for worker in self.owner.workers { worker.requestNativeCleanup() }
            // Even a stuck consumer callback cannot prevent independently observed
            // process fences from satisfying native ownership retirement.
            DispatchQueue.global().async {
                for worker in self.owner.workers { worker.waitForNativeCleanup() }
                self.retired.complete()
            }
        }
        owner.invalidate()
    }

    public func waitUntilRetired() async { await retired.value() }
    public func releaseResources() {
        let release = lock.withLock { () -> Bool in
            guard retired.isComplete && !released else { return false }; released = true; return true
        }
        if release { owner.release(self) }
    }
    func waitForRetirement() { retired.wait() }

    private func event(_ rank: Int) throws -> ClusterWorkerEvent {
        let value = try owner.workers[rank].receiveWorkerEvent(until: reservation.deadlineUptimeNanoseconds, cancelled: { self.isCancelled })
        guard value.requestID == requestID else { throw ClusterWorkerOwnerError.invalid("Stale worker request event") }
        return value.event
    }

    private func run() {
        var acknowledged = [false, false]
        do {
            try lock.withLock {
                guard cancellation == nil else { throw ClusterWorkerOwnerError.cancelled }
                // Enqueue is bounded/nonblocking. Linearize both start commands
                // against cancellation without holding a lock across native IO.
                for worker in owner.workers { try worker.sendWorkerCommand(.start, requestID: requestID, deadline: reservation.deadlineUptimeNanoseconds) }
            }
            var count = 0, last: Int?, cleanStop = false
            var finish: ClusterWorkerFinishReason?
            while finish == nil {
                let value = try event(0)
                switch value {
                case .committedToken(let ordinal, let token, let committed):
                    guard !cleanStop, ordinal == count, count < reservation.outputCount,
                          committed == reservation.promptTokenIDs.count + ordinal, token < owner.profile.vocabularySize,
                          last.map({ !reservation.stopTokenIDs.contains($0) }) ?? true else {
                        throw ClusterWorkerOwnerError.invalid("Unexpected committed worker token")
                    }
                    count += 1; last = token
                    let emit = lock.withLock { callback }
                    let keepGoing = emit?(.token(token)) ?? false
                    if isCancelled { throw ClusterWorkerOwnerError.cancelled }
                    cleanStop = !keepGoing
                    try owner.workers[0].sendWorkerCommand(.tokenDecision(ordinal: ordinal, decision: keepGoing ? .proceed : .cleanStop),
                        requestID: requestID, deadline: reservation.deadlineUptimeNanoseconds)
                case .finished(let reason):
                    guard count > 0, let last else { throw ClusterWorkerOwnerError.invalid("Finish precedes committed token") }
                    let expected: ClusterWorkerFinishReason? = reservation.stopTokenIDs.contains(last) ? .eos
                        : count == reservation.outputCount ? .length : cleanStop ? .clientStop : nil
                    guard reason == expected else { throw ClusterWorkerOwnerError.invalid("Worker clean finish differs") }
                    finish = reason
                default: throw ClusterWorkerOwnerError.invalid("Worker failed or emitted an unexpected request event")
                }
                guard DispatchTime.now().uptimeNanoseconds < reservation.deadlineUptimeNanoseconds else { throw ClusterWorkerOwnerError.deadline }
            }
            guard try event(0) == .retired(.clean) else { throw ClusterWorkerOwnerError.invalid("Rank 0 lacks local retirement") }
            acknowledged[0] = true
            guard try event(1) == .finished(finish!), try event(1) == .retired(.clean) else {
                throw ClusterWorkerOwnerError.invalid("Rank 1 finish or local retirement differs")
            }
            acknowledged[1] = true
            if isCancelled { throw ClusterWorkerOwnerError.cancelled }
            let emit = lock.withLock { callback }; _ = emit?(.finished(finish!))
            retired.complete()
        } catch {
            if retired.isComplete { return }
            cancel(reason: .runtimeError) // Own the watchdog before any callback can block.
            let emit = lock.withLock { callback }
            _ = emit?(.failed("Worker request failed; cleanup is still owned"))
            cleanup(acknowledged: acknowledged)
        }
    }

    private func cleanup(acknowledged original: [Bool]) {
        if retired.isComplete { return }
        var acknowledged = original
        let reason = lock.withLock { cancellation ?? .runtimeError }
        let submitted = lock.withLock { submissions }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        for index in 0..<2 where !acknowledged[index] {
            // Never-submitted/refused ranks have no request to cancel. Pending
            // submission can race an unread refusal, so only confirmed admission
            // permits request cancel. All other ranks need actual native cleanup.
            guard submitted[index] == .admitted else {
                owner.workers[index].requestNativeCleanup()
                continue
            }
            do { try owner.workers[index].sendWorkerCommand(.cancel(reason), requestID: requestID, deadline: deadline) }
            catch { owner.workers[index].requestNativeCleanup() }
        }
        for index in 0..<2 where !acknowledged[index] {
            let worker = owner.workers[index]
            while !worker.nativeCleanupObserved && DispatchTime.now().uptimeNanoseconds < deadline {
                do {
                    let value = try worker.receiveWorkerEvent(until: deadline)
                    guard value.requestID == requestID || value.requestID == nil else { throw ClusterWorkerOwnerError.invalid("Stale cleanup event") }
                    if value.requestID == requestID, case .retired = value.event { acknowledged[index] = true; break }
                    // In-flight committed/finished/failed records cannot undo cancellation.
                } catch { break }
            }
            if !acknowledged[index] {
                worker.requestNativeCleanup(); worker.waitForNativeCleanup() // No timeout can manufacture this acknowledgment.
                acknowledged[index] = true
            }
        }
        retired.complete()
    }
}
