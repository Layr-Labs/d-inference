import Foundation

/// Worker-side command/event ordering for a worker that serves several
/// requests at once (continuous batching, `lanes > 1`). Each request follows
/// exactly the order `ClusterWorkerSession` enforces for its only request
/// (reserve, admitted or refused, start, committed tokens each answered by a
/// decision on rank 0, finished, retired); requests interleave freely.
/// Keep-warm and shutdown need every lane free. With one lane use
/// `ClusterWorkerSession`, which is unchanged.
public struct ClusterWorkerLaneSession: Sendable {
    private enum Phase { case loading, idle, warming, shuttingDown, closed }
    private enum RequestPhase { case reserving, reserved, running, decision, retiring }
    private struct Request: Sendable {
        var phase: RequestPhase
        let reservation: ClusterWorkerReservation
        var tokenCount = 0
        var lastToken: Int?
        var lastDecision: ClusterWorkerTokenDecision?
        var finishReason: ClusterWorkerFinishReason?
        var reusedTokens: Int?
        var cancellation: ClusterWorkerCancellationReason?
        var nativeFailure = false
        var telemetrySent = false
    }
    private let identity: ClusterWorkerIdentity
    private let rank: Int
    private let profile: ClusterWorkerProfile
    private let plan: String
    public let lanes: Int
    private var phase = Phase.loading
    private var commandSequence: UInt64 = 0
    private var eventSequence: UInt64 = 0
    private var seen = Set<UUID>()
    private var seenOrder: [UUID] = []
    private var keepWarmOrdinal: Int?
    private var requests: [UUID: Request] = [:]
    private var capacity = 0
    public private(set) var protocolFailed = false
    public private(set) var locallyAvailable = false
    public var isShutdown: Bool { phase == .closed }
    public var activeRequestIDs: [UUID] { Array(requests.keys) }
    public var keepWarmOutstanding: Bool { phase == .warming }

    public init(identity: ClusterWorkerIdentity, rank: Int, profile: ClusterWorkerProfile,
                executionPlanSHA256: String, lanes: Int) throws {
        try ClusterWorkerValidation.ready(.init(identity: identity, rank: rank, profile: profile,
            executionPlanSHA256: executionPlanSHA256, requestCapacityBytes: 1))
        try workerRequire((2...8).contains(lanes), "A lane session serves 2...8 requests")
        self.identity = identity; self.rank = rank; self.profile = profile; plan = executionPlanSHA256
        self.lanes = lanes
    }

    /// True when `id` is reserved, admitted or running here.
    public func holds(_ id: UUID) -> Bool { requests[id] != nil }
    /// True when rank 0 owes the owner nothing for `id` but its decision.
    public func awaitsDecision(_ id: UUID) -> Bool { requests[id]?.phase == .decision }

    public mutating func accept(_ frame: ClusterWorkerCommandFrame, now: UInt64) throws {
        do {
            try workerRequire(!protocolFailed && phase != .closed, "Worker protocol is terminal")
            try ClusterWorkerValidation.command(frame)
            try workerRequire(frame.membershipEpoch == identity.membershipEpoch && frame.sequence == commandSequence,
                "Stale command epoch or sequence")
            switch frame.command {
            case .reserve(let value):
                try workerRequire(phase == .idle && locallyAvailable && requests.count < lanes,
                    "Worker has no free lane for a reservation")
                guard let id = frame.requestID else { throw ClusterWorkerProtocolError.invalid("Missing request") }
                try workerRequire(!seen.contains(id), "Request ID replay")
                remember(id); requests[id] = .init(phase: .reserving, reservation: value)
            case .start:
                let id = try current(frame.requestID)
                try workerRequire(requests[id]!.phase == .reserved, "Request is not admitted")
                try workerRequire(locallyAvailable, "Readiness was invalidated")
                try deadline(id, now); requests[id]!.phase = .running
            case .tokenDecision(let ordinal, let decision):
                let id = try current(frame.requestID); try deadline(id, now)
                try workerRequire(rank == 0 && requests[id]!.phase == .decision && ordinal == requests[id]!.tokenCount - 1,
                    "Wrong token decision credit")
                requests[id]!.lastDecision = decision; requests[id]!.phase = .running
            case .cancel(let reason):
                let id = try current(frame.requestID)
                requests[id]!.cancellation = requests[id]!.cancellation ?? reason
                requests[id]!.finishReason = nil; requests[id]!.phase = .retiring
            case .shutdown:
                try workerRequire(requests.isEmpty && (phase == .idle || phase == .loading), "Shutdown precedes local retirement")
                locallyAvailable = false; phase = .shuttingDown
            case .keepWarm(let ordinal):
                try workerRequire(phase == .idle && locallyAvailable && requests.isEmpty
                    && ordinal > (keepWarmOrdinal ?? 0), "Keep-warm needs an idle, available worker and a new ordinal")
                keepWarmOrdinal = ordinal; phase = .warming
            }
            commandSequence += 1
        } catch { protocolFailed = true; locallyAvailable = false; throw error }
    }

    public mutating func accept(_ frame: ClusterWorkerEventFrame, now: UInt64) throws {
        do {
            try workerRequire(!protocolFailed && phase != .closed, "Worker protocol is terminal")
            try ClusterWorkerValidation.event(frame)
            try workerRequire(frame.membershipEpoch == identity.membershipEpoch && frame.sequence == eventSequence,
                "Stale event epoch or sequence")
            switch frame.event {
            case .ready(let value):
                try workerRequire(phase == .loading && value.identity == identity && value.rank == rank
                    && value.profile == profile && value.executionPlanSHA256 == plan, "Resident identity differs")
                capacity = value.requestCapacityBytes; locallyAvailable = true; phase = .idle
            case .admitted(let bytes):
                let id = try current(frame.requestID)
                try workerRequire(requests[id]!.phase == .reserving, "Unrequested admission")
                try admission(id, now: now)
                try workerRequire(bytes <= capacity && bytes <= requests[id]!.reservation.capacityLimitBytes,
                    "Reservation exceeds owner ceiling")
                requests[id]!.phase = .reserved
            case .refused(let reason):
                let id = try current(frame.requestID)
                try workerRequire(requests[id]!.phase == .reserving, "Refusal follows admission")
                if reason == .unavailable { locallyAvailable = false }
                requests[id] = nil
            case .committedToken(let ordinal, let token, let committed):
                let id = try current(frame.requestID); try deadline(id, now)
                let r = requests[id]!
                try workerRequire(rank == 0 && r.phase == .running && r.lastDecision != .cleanStop && ordinal == r.tokenCount
                    && r.tokenCount < r.reservation.outputCount && token < profile.vocabularySize
                    && committed == r.reservation.promptTokenIDs.count + ordinal, "Token is not the next committed output")
                if let last = r.lastToken { try workerRequire(!r.reservation.stopTokenIDs.contains(last), "Token follows EOS") }
                requests[id]!.tokenCount += 1; requests[id]!.lastToken = token
                requests[id]!.lastDecision = nil; requests[id]!.phase = .decision
            case .promptCache(let reused, let stored):
                let id = try current(frame.requestID); try deadline(id, now)
                let r = requests[id]!, prompt = r.reservation.promptTokenIDs.count
                try workerRequire(r.phase == .running && r.reusedTokens == nil && reused < prompt
                    && stored.allSatisfy({ $0 < prompt })
                    && (rank == 1 || (r.tokenCount > 0 && r.lastDecision != nil)), "Prompt cache report is out of order")
                requests[id]!.reusedTokens = reused
            case .requestTelemetry:
                let id = try current(frame.requestID); try deadline(id, now)
                let r = requests[id]!
                // Once per request, before its finish, after any prompt cache report.
                try workerRequire(r.phase == .running && !r.telemetrySent
                    && (rank == 1 || (r.tokenCount > 0 && r.lastDecision != nil)), "Request telemetry is out of order")
                requests[id]!.telemetrySent = true
            case .finished(let reason):
                let id = try current(frame.requestID); try deadline(id, now)
                let r = requests[id]!
                if rank == 1 {
                    try workerRequire(r.phase == .running, "Rank 1 finish precedes request start")
                    requests[id]!.finishReason = reason; requests[id]!.phase = .retiring
                    break
                }
                try workerRequire(r.phase == .running && r.tokenCount > 0 && r.lastDecision != nil, "Finish precedes token decision")
                let expected: ClusterWorkerFinishReason?
                if r.reservation.stopTokenIDs.contains(r.lastToken!) { expected = .eos }
                else if r.tokenCount == r.reservation.outputCount { expected = .length }
                else { expected = r.lastDecision == .cleanStop ? .clientStop : nil }
                try workerRequire(expected == reason, "Clean finish reason differs")
                requests[id]!.finishReason = reason; requests[id]!.phase = .retiring
            case .failed:
                let id = try current(frame.requestID)
                requests[id]!.nativeFailure = true; requests[id]!.finishReason = nil
                locallyAvailable = false; requests[id]!.phase = .retiring
            case .retired(let outcome):
                let id = try current(frame.requestID)
                let r = requests[id]!
                try workerRequire(r.phase == .retiring, "Retirement lacks a terminal path")
                let valid = outcome == .clean ? r.finishReason != nil && r.cancellation == nil && !r.nativeFailure
                    : outcome == .cancelled ? r.cancellation != nil && !r.nativeFailure : r.nativeFailure || r.cancellation != nil
                try workerRequire(valid, "Retirement outcome differs from terminal path")
                if outcome == .failed { locallyAvailable = false }
                requests[id] = nil
            case .unavailable:
                locallyAvailable = false
            case .shutdownComplete:
                try workerRequire(phase == .shuttingDown && requests.isEmpty, "Unrequested shutdown acknowledgment")
                phase = .closed
            case .keptWarm(let ordinal, _, let serving):
                try workerRequire(phase == .warming && ordinal == keepWarmOrdinal
                    && (serving.map { $0 <= profile.maximumContextTokens } ?? true), "Unrequested keep-warm acknowledgment")
                phase = .idle
            }
            eventSequence += 1
        } catch { protocolFailed = true; locallyAvailable = false; throw error }
    }

    private mutating func remember(_ id: UUID) {
        seen.insert(id); seenOrder.append(id)
        if seenOrder.count > ClusterWorkerLimits.requestReplayWindow { seen.remove(seenOrder.removeFirst()) }
    }

    private func current(_ id: UUID?) throws -> UUID {
        guard let id, requests[id] != nil else { throw ClusterWorkerProtocolError.invalid("Stale request ID") }
        return id
    }
    private func deadline(_ id: UUID, _ now: UInt64) throws {
        try workerRequire(now < requests[id]!.reservation.deadlineUptimeNanoseconds, "Local request deadline elapsed")
    }
    private func admission(_ id: UUID, now: UInt64) throws {
        try deadline(id, now)
        let r = requests[id]!.reservation
        try workerRequire(locallyAvailable && r.deadlineUptimeNanoseconds - now <= ClusterWorkerLimits.deadlineNanoseconds
            && r.profileID == profile.id && r.promptTokenIDs.count <= profile.maximumPromptTokens
            && r.outputCount <= profile.maximumOutputTokens && r.chunkSize <= profile.maximumChunkTokens
            && r.promptTokenIDs.count <= profile.maximumContextTokens - r.outputCount
            && (r.promptTokenIDs + r.stopTokenIDs).allSatisfy({ $0 < profile.vocabularySize }), "Reservation exceeds resident profile/deadline")
    }
}
