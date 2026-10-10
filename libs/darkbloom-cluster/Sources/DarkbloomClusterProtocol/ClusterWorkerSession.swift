import Foundation

/// Serial worker-side command/event ordering. This is not a resource permit,
/// peer agreement, scheduler or fencing implementation. Do not use it as a
/// total-order mirror of two independently arriving pipes on the provider side.
public struct ClusterWorkerSession: Sendable {
    private enum Phase { case loading, idle, reserving, reserved, running, decision, retiring, shuttingDown, closed }
    private let identity: ClusterWorkerIdentity
    private let rank: Int
    private let profile: ClusterWorkerProfile
    private let plan: String
    private var phase = Phase.loading
    private var commandSequence: UInt64 = 0
    private var eventSequence: UInt64 = 0
    private var seen = Set<UUID>()
    private var requestID: UUID?
    private var request: ClusterWorkerReservation?
    private var capacity = 0
    private var tokenCount = 0
    private var lastToken: Int?
    private var lastDecision: ClusterWorkerTokenDecision?
    private var finishReason: ClusterWorkerFinishReason?
    private var cancellation: ClusterWorkerCancellationReason?
    private var nativeFailure = false
    public private(set) var protocolFailed = false
    public private(set) var locallyAvailable = false
    public private(set) var lastLocalRetirementRequestID: UUID?
    public var isShutdown: Bool { phase == .closed }
    public var activeRequestID: UUID? { requestID }

    public init(identity: ClusterWorkerIdentity, rank: Int, profile: ClusterWorkerProfile, executionPlanSHA256: String) throws {
        try ClusterWorkerValidation.ready(.init(identity: identity, rank: rank, profile: profile,
            executionPlanSHA256: executionPlanSHA256, requestCapacityBytes: 1))
        self.identity = identity; self.rank = rank; self.profile = profile; plan = executionPlanSHA256
    }

    /// now is the worker's actual local uptime. The caller still checks it while
    /// waiting on a token decision and during every blocking native operation.
    public mutating func accept(_ frame: ClusterWorkerCommandFrame, now: UInt64) throws {
        do {
            try workerRequire(!protocolFailed && phase != .closed, "Worker protocol is terminal")
            try ClusterWorkerValidation.command(frame)
            try workerRequire(frame.membershipEpoch == identity.membershipEpoch && frame.sequence == commandSequence,
                "Stale command epoch or sequence")
            switch frame.command {
            case .reserve(let value):
                try workerRequire(phase == .idle && locallyAvailable && requestID == nil,
                    "Worker is not available for a reservation")
                guard let id = frame.requestID else { throw ClusterWorkerProtocolError.invalid("Missing request") }
                try workerRequire(seen.count < ClusterWorkerLimits.requestsPerEpoch && !seen.contains(id),
                    "Request ID replay or epoch request limit")
                seen.insert(id); requestID = id; request = value; phase = .reserving
                tokenCount = 0; lastToken = nil; lastDecision = nil; finishReason = nil; cancellation = nil; nativeFailure = false
            case .start:
                try current(frame.requestID); try workerRequire(phase == .reserved, "Request is not admitted")
                try workerRequire(locallyAvailable, "Readiness was invalidated")
                try deadline(now); phase = .running
            case .tokenDecision(let ordinal, let decision):
                try current(frame.requestID); try deadline(now)
                try workerRequire(rank == 0 && phase == .decision && ordinal == tokenCount - 1, "Wrong token decision credit")
                lastDecision = decision; phase = .running
            case .cancel(let reason):
                try current(frame.requestID)
                try workerRequire(phase != .loading && phase != .idle && phase != .shuttingDown, "No request to cancel")
                cancellation = cancellation ?? reason; finishReason = nil; phase = .retiring
            case .shutdown:
                try workerRequire(requestID == nil && (phase == .idle || phase == .loading), "Shutdown precedes local retirement")
                locallyAvailable = false; phase = .shuttingDown
            }
            commandSequence += 1
        } catch { protocolFailed = true; locallyAvailable = false; throw error }
    }

    /// Call at actual event publication on the same serial executor as accept(command).
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
                try current(frame.requestID); try workerRequire(phase == .reserving, "Unrequested admission")
                try admission(now: now)
                try workerRequire(bytes <= capacity && bytes <= request!.capacityLimitBytes, "Reservation exceeds owner ceiling")
                phase = .reserved
            case .refused(let reason):
                try current(frame.requestID); try workerRequire(phase == .reserving, "Refusal follows admission")
                if reason == .unavailable { locallyAvailable = false }
                requestID = nil; request = nil; phase = .idle
            case .committedToken(let ordinal, let token, let committed):
                try current(frame.requestID); try deadline(now)
                try workerRequire(rank == 0 && phase == .running && lastDecision != .cleanStop && ordinal == tokenCount
                    && tokenCount < request!.outputCount && token < profile.vocabularySize
                    && committed == request!.promptTokenIDs.count + ordinal, "Token is not the next committed output")
                // A prior EOS/limit decision cannot authorize another token.
                if let lastToken { try workerRequire(!request!.stopTokenIDs.contains(lastToken), "Token follows EOS") }
                tokenCount += 1; lastToken = token; lastDecision = nil; phase = .decision
            case .finished(let reason):
                try current(frame.requestID); try deadline(now)
                // Only rank 0 owns the provider callback. Rank 1 reports the actual
                // native result; its token/finish agreement stays on the peer channel.
                if rank == 1 {
                    try workerRequire(phase == .running, "Rank 1 finish precedes request start")
                    finishReason = reason; phase = .retiring
                    break
                }
                try workerRequire(phase == .running && tokenCount > 0 && lastDecision != nil, "Finish precedes token decision")
                let expected: ClusterWorkerFinishReason?
                if request!.stopTokenIDs.contains(lastToken!) { expected = .eos }
                else if tokenCount == request!.outputCount { expected = .length }
                else { expected = lastDecision == .cleanStop ? .clientStop : nil }
                try workerRequire(expected == reason, "Clean finish reason differs")
                finishReason = reason; phase = .retiring
            case .failed:
                try current(frame.requestID); nativeFailure = true; finishReason = nil
                locallyAvailable = false; phase = .retiring
            case .retired(let outcome):
                try current(frame.requestID); try workerRequire(phase == .retiring, "Retirement lacks a terminal path")
                let valid = outcome == .clean ? finishReason != nil && cancellation == nil && !nativeFailure
                    : outcome == .cancelled ? cancellation != nil && !nativeFailure : nativeFailure || cancellation != nil
                try workerRequire(valid, "Retirement outcome differs from terminal path")
                if outcome == .failed { locallyAvailable = false }
                lastLocalRetirementRequestID = requestID
                requestID = nil; request = nil; phase = .idle
            case .unavailable:
                locallyAvailable = false
            case .shutdownComplete:
                try workerRequire(phase == .shuttingDown && requestID == nil, "Unrequested shutdown acknowledgment")
                phase = .closed
            }
            eventSequence += 1
        } catch { protocolFailed = true; locallyAvailable = false; throw error }
    }

    private func current(_ id: UUID?) throws {
        try workerRequire(id != nil && id == requestID && request != nil, "Stale request ID")
    }
    private func deadline(_ now: UInt64) throws {
        guard let request else { throw ClusterWorkerProtocolError.invalid("Missing request deadline") }
        try workerRequire(now < request.deadlineUptimeNanoseconds, "Local request deadline elapsed")
    }
    private func admission(now: UInt64) throws {
        try deadline(now)
        let r = request!
        try workerRequire(locallyAvailable && r.deadlineUptimeNanoseconds - now <= ClusterWorkerLimits.deadlineNanoseconds
            && r.profileID == profile.id && r.promptTokenIDs.count <= profile.maximumPromptTokens
            && r.outputCount <= profile.maximumOutputTokens && r.chunkSize <= profile.maximumChunkTokens
            && r.promptTokenIDs.count <= profile.maximumContextTokens - r.outputCount
            && (r.promptTokenIDs + r.stopTokenIDs).allSatisfy({ $0 < profile.vocabularySize }), "Reservation exceeds resident profile/deadline")
    }
}
