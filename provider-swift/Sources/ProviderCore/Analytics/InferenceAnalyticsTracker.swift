import Foundation

/// Per-request state used to collapse the inference lifecycle into one terminal
/// analytics event. The tracker is thread-safe and emits at most once.
final class InferenceAnalyticsTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let servingMode: String
    private let processEpoch: String
    private let jobID = UUID().uuidString.lowercased()
    private let startedAt = Date()
    private var admittedAt: Date?
    private var firstContentAt: Date?
    private var model: String?
    private var streaming: Bool
    private var finished = false

    init(servingMode: String, model: String?, streaming: Bool) {
        self.servingMode = servingMode
        self.model = model
        self.streaming = streaming
        self.processEpoch = LocalAnalytics.shared.processEpoch
    }

    func updateRequest(model: String, streaming: Bool) {
        lock.lock()
        self.model = model
        self.streaming = streaming
        lock.unlock()
    }

    func noteAdmitted() {
        lock.lock()
        if admittedAt == nil { admittedAt = Date() }
        lock.unlock()
    }

    func noteFirstContent() {
        lock.lock()
        if firstContentAt == nil { firstContentAt = Date() }
        lock.unlock()
    }

    func finish(
        outcome: String,
        errorClass: String? = nil,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        cachedPromptTokens: Int = 0
    ) {
        let event: LocalAnalyticsEvent
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let endedAt = Date()
        let queueMS = admittedAt.map { max(0, $0.timeIntervalSince(startedAt) * 1_000) }
        let ttftMS = firstContentAt.map { max(0, $0.timeIntervalSince(startedAt) * 1_000) }
        let totalMS = max(0, endedAt.timeIntervalSince(startedAt) * 1_000)
        let decodeSeconds = firstContentAt.map { max(0, endedAt.timeIntervalSince($0)) }
        let decodeTPS = decodeSeconds.flatMap { seconds in
            seconds > 0 && completionTokens > 0 ? Double(completionTokens) / seconds : nil
        }
        event = LocalAnalyticsEvent(
            eventAt: endedAt,
            processEpoch: processEpoch,
            jobID: jobID,
            servingMode: servingMode,
            model: model,
            outcome: outcome,
            errorClass: errorClass,
            streaming: streaming,
            promptTokens: Int64(max(0, promptTokens)),
            completionTokens: Int64(max(0, completionTokens)),
            cachedPromptTokens: Int64(max(0, cachedPromptTokens)),
            queueMS: queueMS,
            ttftMS: ttftMS,
            totalMS: totalMS,
            decodeTPS: decodeTPS)
        lock.unlock()
        LocalAnalytics.shared.record(event)
    }

    func finish(outbound message: OutboundMessage) {
        switch message {
        case .inferenceComplete(_, let usage, _, _, _):
            finish(
                outcome: "success",
                promptTokens: Int(clamping: usage.promptTokens),
                completionTokens: Int(clamping: usage.completionTokens),
                cachedPromptTokens: Int(clamping: usage.cachedTokens ?? 0))
        case .inferenceError(_, let failure):
            let usage = failure.attemptUsage
            let outcome: String
            if failure.code == .cancelled || failure.terminalCause == .cancelled {
                outcome = "cancelled"
            } else if [
                .invalidRequest, .invalidMedia, .mediaTooLarge, .unsupportedMedia,
                .modelUnavailable, .capacity,
            ].contains(failure.code) {
                outcome = "rejected"
            } else {
                outcome = "failed"
            }
            finish(
                outcome: outcome,
                errorClass: failure.terminalCause?.rawValue ?? failure.code.rawValue,
                promptTokens: Int(clamping: usage?.promptTokens ?? 0),
                completionTokens: Int(clamping: usage?.completionTokens ?? 0),
                cachedPromptTokens: Int(clamping: usage?.cachedTokens ?? 0))
        default:
            break
        }
    }
}

enum InferenceAnalyticsClassification {
    static func outcome(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? MultiModelBatchSchedulerEngineError {
            switch error {
            case .queueFull, .modelNotLoaded, .noModelLoadedForTokenization,
                .invalidRole, .invalidToolPayload, .tokenBudgetExhausted,
                .requestRejected, .mediaUnsupportedByModel, .multimodalRejected:
                return "rejected"
            default:
                return "failed"
            }
        }
        return "failed"
    }

    static func errorClass(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? MultiModelBatchSchedulerEngineError {
            switch error {
            case .queueFull: return "capacity"
            case .tokenBudgetExhausted: return "capacity"
            case .modelNotLoaded: return "model_unavailable"
            case .noModelLoadedForTokenization: return "model_unavailable"
            case .toolChoiceViolation: return "tool_policy"
            case .invalidToolPayload: return "invalid_request"
            case .invalidRole: return "invalid_request"
            case .requestRejected: return "invalid_request"
            case .mediaUnsupportedByModel: return "unsupported_media"
            case .multimodalRejected: return "invalid_media"
            case .platformTerminal(let cause, _, _): return cause.rawValue
            default: return "generation"
            }
        }
        return "internal"
    }
}
