import Foundation

public struct BatchSchedulingPolicy: Sendable, Equatable {
    public let maxConcurrentRequests: Int
    public let maxQueuedRequests: Int
    public let maxActiveTokenBudget: Int
    public let maxTokensPerBatch: Int

    public init(
        maxConcurrentRequests: Int = 4,
        maxQueuedRequests: Int = 128,
        maxActiveTokenBudget: Int = 32_768,
        maxTokensPerBatch: Int = 4_096
    ) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maxQueuedRequests = max(0, maxQueuedRequests)
        self.maxActiveTokenBudget = max(1, maxActiveTokenBudget)
        self.maxTokensPerBatch = max(1, maxTokensPerBatch)
    }

    public static let `default` = BatchSchedulingPolicy()
}

public struct BatchRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let promptTokenCount: Int
    public let maxOutputTokens: Int

    public init(id: String, promptTokenCount: Int, maxOutputTokens: Int) {
        self.id = id
        self.promptTokenCount = promptTokenCount
        self.maxOutputTokens = maxOutputTokens
    }

    public var reservedTokenCount: Int {
        promptTokenCount + maxOutputTokens
    }
}

public enum BatchRejectionReason: Sendable, Equatable {
    case duplicateRequestID
    case invalidTokenCount
    case requestExceedsActiveTokenBudget
    case requestExceedsBatchTokenBudget
    case queueFull
}

public enum BatchAdmissionResult: Sendable, Equatable {
    case queued(requestID: String, position: Int)
    case rejected(requestID: String, reason: BatchRejectionReason)
}

public enum BatchRequestPhase: String, Sendable, Equatable {
    case pendingPrefill
    case prefilling
    case decoding
}

public enum BatchStepKind: String, Sendable, Equatable {
    case prefill
    case decode
}

public struct BatchScheduledRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let sequence: UInt64
    public let kind: BatchStepKind
    public let inputTokenCount: Int
    public let promptTokenCount: Int
    public let generatedTokenCount: Int
    public let maxOutputTokens: Int

    public init(
        id: String,
        sequence: UInt64,
        kind: BatchStepKind,
        inputTokenCount: Int,
        promptTokenCount: Int,
        generatedTokenCount: Int,
        maxOutputTokens: Int
    ) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.inputTokenCount = inputTokenCount
        self.promptTokenCount = promptTokenCount
        self.generatedTokenCount = generatedTokenCount
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ScheduledBatch: Sendable, Equatable {
    public let sequence: UInt64
    public let prefill: BatchScheduledRequest?
    public let decodes: [BatchScheduledRequest]
    public let tokenCost: Int
    public let activeTokenBudgetUsed: Int

    public init(
        sequence: UInt64,
        prefill: BatchScheduledRequest?,
        decodes: [BatchScheduledRequest],
        tokenCost: Int,
        activeTokenBudgetUsed: Int
    ) {
        self.sequence = sequence
        self.prefill = prefill
        self.decodes = decodes
        self.tokenCost = tokenCost
        self.activeTokenBudgetUsed = activeTokenBudgetUsed
    }

    public var orderedRequests: [BatchScheduledRequest] {
        decodes + (prefill.map { [$0] } ?? [])
    }
}

public struct BatchRequestSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let sequence: UInt64
    public let phase: BatchRequestPhase
    public let promptTokenCount: Int
    public let generatedTokenCount: Int
    public let maxOutputTokens: Int
    public let reservedTokenCount: Int

    public init(
        id: String,
        sequence: UInt64,
        phase: BatchRequestPhase,
        promptTokenCount: Int,
        generatedTokenCount: Int,
        maxOutputTokens: Int,
        reservedTokenCount: Int
    ) {
        self.id = id
        self.sequence = sequence
        self.phase = phase
        self.promptTokenCount = promptTokenCount
        self.generatedTokenCount = generatedTokenCount
        self.maxOutputTokens = maxOutputTokens
        self.reservedTokenCount = reservedTokenCount
    }
}

public struct BatchSchedulerSnapshot: Sendable, Equatable {
    public let pendingRequests: [BatchRequestSnapshot]
    public let activeRequests: [BatchRequestSnapshot]
    public let activeTokenBudgetUsed: Int
    public let queuedTokenBudget: Int
    public let policy: BatchSchedulingPolicy

    public init(
        pendingRequests: [BatchRequestSnapshot],
        activeRequests: [BatchRequestSnapshot],
        activeTokenBudgetUsed: Int,
        queuedTokenBudget: Int,
        policy: BatchSchedulingPolicy
    ) {
        self.pendingRequests = pendingRequests
        self.activeRequests = activeRequests
        self.activeTokenBudgetUsed = activeTokenBudgetUsed
        self.queuedTokenBudget = queuedTokenBudget
        self.policy = policy
    }

    public var pendingRequestIDs: [String] {
        pendingRequests.map(\.id)
    }

    public var activeRequestIDs: [String] {
        activeRequests.map(\.id)
    }
}

public enum DecodeStepOutcome: Sendable, Equatable {
    case generated(remainingTokens: Int)
    case completed
    case notFound
}

public actor BatchQueuePlanner {
    private struct QueuedRequest: Sendable {
        let request: BatchRequest
        let sequence: UInt64
    }

    private struct ActiveRequest: Sendable {
        let request: BatchRequest
        let sequence: UInt64
        var phase: BatchRequestPhase
        var generatedTokenCount: Int
    }

    public let policy: BatchSchedulingPolicy

    private var nextRequestSequence: UInt64 = 0
    private var nextBatchSequence: UInt64 = 0
    private var pending: [QueuedRequest] = []
    private var active: [String: ActiveRequest] = [:]
    private var activeOrder: [String] = []

    public init(policy: BatchSchedulingPolicy = .default) {
        self.policy = policy
    }

    @discardableResult
    public func admit(_ request: BatchRequest) -> BatchAdmissionResult {
        guard request.promptTokenCount > 0, request.maxOutputTokens > 0 else {
            return .rejected(requestID: request.id, reason: .invalidTokenCount)
        }

        guard request.reservedTokenCount <= policy.maxActiveTokenBudget else {
            return .rejected(requestID: request.id, reason: .requestExceedsActiveTokenBudget)
        }

        guard request.promptTokenCount <= policy.maxTokensPerBatch else {
            return .rejected(requestID: request.id, reason: .requestExceedsBatchTokenBudget)
        }

        guard !contains(requestID: request.id) else {
            return .rejected(requestID: request.id, reason: .duplicateRequestID)
        }

        guard pending.count < policy.maxQueuedRequests else {
            return .rejected(requestID: request.id, reason: .queueFull)
        }

        nextRequestSequence += 1
        pending.append(QueuedRequest(request: request, sequence: nextRequestSequence))
        return .queued(requestID: request.id, position: pending.count)
    }

    @discardableResult
    public func admit(
        id: String,
        promptTokenCount: Int,
        maxOutputTokens: Int
    ) -> BatchAdmissionResult {
        admit(BatchRequest(
            id: id,
            promptTokenCount: promptTokenCount,
            maxOutputTokens: maxOutputTokens
        ))
    }

    public func nextBatch() -> ScheduledBatch? {
        var remainingTokenBudget = policy.maxTokensPerBatch
        let decodes = decodeRequests(fittingIn: &remainingTokenBudget)
        let prefill = prefillRequest(fittingIn: remainingTokenBudget)

        guard prefill != nil || !decodes.isEmpty else {
            return nil
        }

        let tokenCost = decodes.reduce(prefill?.inputTokenCount ?? 0) {
            $0 + $1.inputTokenCount
        }

        nextBatchSequence += 1
        return ScheduledBatch(
            sequence: nextBatchSequence,
            prefill: prefill,
            decodes: decodes,
            tokenCost: tokenCost,
            activeTokenBudgetUsed: activeTokenBudgetUsed
        )
    }

    @discardableResult
    public func markPrefillComplete(requestID: String) -> Bool {
        guard var request = active[requestID], request.phase == .prefilling else {
            return false
        }

        request.phase = .decoding
        active[requestID] = request
        return true
    }

    @discardableResult
    public func recordDecodeStep(
        requestID: String,
        generatedTokens: Int = 1
    ) -> DecodeStepOutcome {
        guard var request = active[requestID], request.phase == .decoding else {
            return .notFound
        }

        request.generatedTokenCount += max(0, generatedTokens)
        if request.generatedTokenCount >= request.request.maxOutputTokens {
            removeActive(requestID: requestID)
            return .completed
        }

        active[requestID] = request
        return .generated(
            remainingTokens: request.request.maxOutputTokens - request.generatedTokenCount
        )
    }

    @discardableResult
    public func complete(requestID: String) -> Bool {
        guard active[requestID] != nil else {
            return false
        }

        removeActive(requestID: requestID)
        return true
    }

    @discardableResult
    public func cancel(requestID: String) -> Bool {
        if let index = pending.firstIndex(where: { $0.request.id == requestID }) {
            pending.remove(at: index)
            return true
        }

        guard active[requestID] != nil else {
            return false
        }

        removeActive(requestID: requestID)
        return true
    }

    public func snapshot() -> BatchSchedulerSnapshot {
        let pendingSnapshots = pending.map { queued in
            snapshot(for: queued)
        }
        let activeSnapshots = activeOrder.compactMap { requestID in
            active[requestID].map { snapshot(for: $0) }
        }

        return BatchSchedulerSnapshot(
            pendingRequests: pendingSnapshots,
            activeRequests: activeSnapshots,
            activeTokenBudgetUsed: activeTokenBudgetUsed,
            queuedTokenBudget: pending.reduce(0) { $0 + $1.request.reservedTokenCount },
            policy: policy
        )
    }

    private func decodeRequests(fittingIn remainingTokenBudget: inout Int) -> [BatchScheduledRequest] {
        var scheduled: [BatchScheduledRequest] = []

        for requestID in activeOrder {
            guard remainingTokenBudget > 0 else {
                break
            }
            guard let request = active[requestID], request.phase == .decoding else {
                continue
            }

            scheduled.append(scheduledRequest(for: request, kind: .decode))
            remainingTokenBudget -= 1
        }

        return scheduled
    }

    private func prefillRequest(fittingIn remainingTokenBudget: Int) -> BatchScheduledRequest? {
        guard let next = pending.first else {
            return nil
        }
        guard active.count < policy.maxConcurrentRequests else {
            return nil
        }
        guard next.request.promptTokenCount <= remainingTokenBudget else {
            return nil
        }
        guard activeTokenBudgetUsed + next.request.reservedTokenCount <= policy.maxActiveTokenBudget
        else {
            return nil
        }

        pending.removeFirst()

        let activeRequest = ActiveRequest(
            request: next.request,
            sequence: next.sequence,
            phase: .prefilling,
            generatedTokenCount: 0
        )
        active[next.request.id] = activeRequest
        activeOrder.append(next.request.id)

        return scheduledRequest(for: activeRequest, kind: .prefill)
    }

    private func contains(requestID: String) -> Bool {
        active[requestID] != nil || pending.contains { $0.request.id == requestID }
    }

    private var activeTokenBudgetUsed: Int {
        active.values.reduce(0) { $0 + $1.request.reservedTokenCount }
    }

    private func removeActive(requestID: String) {
        active.removeValue(forKey: requestID)
        activeOrder.removeAll { $0 == requestID }
    }

    private func scheduledRequest(
        for activeRequest: ActiveRequest,
        kind: BatchStepKind
    ) -> BatchScheduledRequest {
        BatchScheduledRequest(
            id: activeRequest.request.id,
            sequence: activeRequest.sequence,
            kind: kind,
            inputTokenCount: kind == .prefill ? activeRequest.request.promptTokenCount : 1,
            promptTokenCount: activeRequest.request.promptTokenCount,
            generatedTokenCount: activeRequest.generatedTokenCount,
            maxOutputTokens: activeRequest.request.maxOutputTokens
        )
    }

    private func snapshot(for queued: QueuedRequest) -> BatchRequestSnapshot {
        BatchRequestSnapshot(
            id: queued.request.id,
            sequence: queued.sequence,
            phase: .pendingPrefill,
            promptTokenCount: queued.request.promptTokenCount,
            generatedTokenCount: 0,
            maxOutputTokens: queued.request.maxOutputTokens,
            reservedTokenCount: queued.request.reservedTokenCount
        )
    }

    private func snapshot(for activeRequest: ActiveRequest) -> BatchRequestSnapshot {
        BatchRequestSnapshot(
            id: activeRequest.request.id,
            sequence: activeRequest.sequence,
            phase: activeRequest.phase,
            promptTokenCount: activeRequest.request.promptTokenCount,
            generatedTokenCount: activeRequest.generatedTokenCount,
            maxOutputTokens: activeRequest.request.maxOutputTokens,
            reservedTokenCount: activeRequest.request.reservedTokenCount
        )
    }
}
