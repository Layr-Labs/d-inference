import Foundation

/// Lightweight request progress used to build capacity snapshots without
/// depending on MLX runtime state. `completionTokens == 0` is treated as
/// pending/prefill until the first token is observed.
public struct InferenceRequestProgress: Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let firstTokenReceived: Bool

    public init(
        promptTokens: Int,
        completionTokens: Int,
        firstTokenReceived: Bool
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.firstTokenReceived = firstTokenReceived
    }
}

public struct SchedulerCapacityCounters: Sendable, Equatable {
    public let activeRequests: Int
    public let pendingRequests: Int
    public let activeTokens: Int

    public init(activeRequests: Int, pendingRequests: Int, activeTokens: Int) {
        self.activeRequests = activeRequests
        self.pendingRequests = pendingRequests
        self.activeTokens = activeTokens
    }

    public static func from(_ requests: some Sequence<InferenceRequestProgress>) -> SchedulerCapacityCounters {
        var activeRequests = 0
        var pendingRequests = 0
        var activeTokens = 0

        for request in requests {
            activeRequests += 1
            if !request.firstTokenReceived {
                pendingRequests += 1
            }
            activeTokens += max(0, request.promptTokens) + max(0, request.completionTokens)
        }

        return SchedulerCapacityCounters(
            activeRequests: activeRequests,
            pendingRequests: pendingRequests,
            activeTokens: activeTokens
        )
    }
}

public enum InferenceLifecycleTelemetryStage: String, Sendable, Equatable {
    case schedulerAdmit = "scheduler_admit"
    case firstToken = "first_token"
    case inferenceComplete = "inference_complete"
    case inferenceError = "inference_error"
    case inferenceCancel = "inference_cancel"
}

public struct InferenceLifecycleTelemetrySnapshot: Sendable, Equatable {
    public let requestId: String
    public let model: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let queueMilliseconds: Double?
    public let admitMilliseconds: Double?
    public let ttftMilliseconds: Double?
    public let totalMilliseconds: Double?
    public let activeCount: Int?

    public init(
        requestId: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        queueMilliseconds: Double? = nil,
        admitMilliseconds: Double? = nil,
        ttftMilliseconds: Double? = nil,
        totalMilliseconds: Double? = nil,
        activeCount: Int? = nil
    ) {
        self.requestId = requestId
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.queueMilliseconds = queueMilliseconds
        self.admitMilliseconds = admitMilliseconds
        self.ttftMilliseconds = ttftMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.activeCount = activeCount
    }
}

public enum InferenceLifecycleTelemetry {
    public static func event(
        _ stage: InferenceLifecycleTelemetryStage,
        snapshot: InferenceLifecycleTelemetrySnapshot,
        error: String? = nil,
        reason: String? = nil
    ) -> TelemetryEvent {
        var fields: [String: AnyCodableValue] = [
            "component": .string("batch_scheduler"),
            "operation": .string(stage.rawValue),
            "model": .string(snapshot.model),
            "prompt_tokens": .int(snapshot.promptTokens),
            "completion_tokens": .int(snapshot.completionTokens),
        ]

        if let queueMilliseconds = snapshot.queueMilliseconds {
            fields["queue_ms"] = .double(queueMilliseconds)
        }
        if let admitMilliseconds = snapshot.admitMilliseconds {
            fields["admit_ms"] = .double(admitMilliseconds)
        }
        if let ttftMilliseconds = snapshot.ttftMilliseconds {
            fields["ttft_ms"] = .double(ttftMilliseconds)
        }
        if let totalMilliseconds = snapshot.totalMilliseconds {
            fields["total_ms"] = .double(totalMilliseconds)
            // Preserve compatibility with existing dashboards that key on the
            // generic duration field while still emitting the explicit metric.
            fields["duration_ms"] = .double(totalMilliseconds)
        }
        if let activeCount = snapshot.activeCount {
            fields["active_count"] = .int(activeCount)
            fields["queue_depth"] = .int(activeCount)
        }
        if let error {
            fields["error"] = .string(error)
        }
        if let reason {
            fields["reason"] = .string(reason)
        }

        return TelemetryEvent(
            source: .provider,
            severity: severity(for: stage),
            kind: kind(for: stage),
            message: stage.rawValue
        )
        .withRequestId(snapshot.requestId)
        .withFields(fields)
    }

    public static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000.0)
            + (Double(components.attoseconds) / 1e15)
    }

    private static func severity(for stage: InferenceLifecycleTelemetryStage) -> TelemetrySeverity {
        switch stage {
        case .inferenceError:
            return .error
        case .inferenceCancel:
            return .warn
        case .schedulerAdmit, .firstToken, .inferenceComplete:
            return .info
        }
    }

    private static func kind(for stage: InferenceLifecycleTelemetryStage) -> TelemetryKind {
        switch stage {
        case .inferenceError:
            return .inferenceError
        case .schedulerAdmit, .firstToken, .inferenceComplete, .inferenceCancel:
            return .custom
        }
    }
}