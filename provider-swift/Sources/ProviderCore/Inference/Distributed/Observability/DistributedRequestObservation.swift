import Foundation
import MLXLMCommon

/// Provider-local lifecycle timings, not external TTFT or native kernel timing.
/// Value snapshots are made on the engine queue; callbacks run on a separate
/// bounded serial sink and cannot hold up cancellation or retirement.
/// No prompt, output token, arbitrary error text, or remote clock is included.
public struct DistributedRequestObservation: Sendable {
    public enum Phase: String, Sendable { case reserved, firstToken, terminal, retired }
    public let generation: UUID
    public let phase: Phase
    public let promptTokens: Int
    public let completionTokens: Int
    public let admissionElapsedMilliseconds: Double
    public let reservationMilliseconds: Double
    public let remainingFirstTokenMilliseconds: Double?
    public let outcome: String?
    /// Cumulative observations discarded by this engine's bounded sink before
    /// this delivery. Drop-newest overflow; saturates at UInt64.max.
    public private(set) var droppedObservations: UInt64 = 0

    func delivered(droppedObservations: UInt64) -> Self {
        var result = self; result.droppedObservations = droppedObservations; return result
    }

    init(state: DistributedRequestState, phase: Phase, now: ContinuousClock.Instant,
         reason: CBv2FinishReason? = nil) {
        generation = state.generation
        self.phase = phase
        promptTokens = state.request.promptTokens.count
        completionTokens = state.completionTokens
        admissionElapsedMilliseconds = Self.milliseconds(state.admissionStartedAt.duration(to: now))
        reservationMilliseconds = Self.milliseconds(state.admissionStartedAt.duration(to: state.reservedAt))
        remainingFirstTokenMilliseconds = state.firstTokenDeadline.map { Self.milliseconds(now.duration(to: $0)) }
        outcome = reason.map(Self.outcome)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    static func outcome(_ reason: CBv2FinishReason) -> String {
        switch reason {
        case .stop: return "stop"
        case .length: return "length"
        case .cancelled: return "cancelled"
        case .error: return "engine_error"
        case .terminal(let cause, _):
            switch cause {
            case .admissionTimeout: return "admission_timeout"
            case .prefillStall: return "prefill_stall"
            case .decodeStall: return "decode_stall"
            case .safetyDeadline: return "safety_deadline"
            case .backpressureTimeout: return "backpressure_timeout"
            case .watchdog: return "watchdog"
            case .legacyRequestTimeout: return "legacy_request_timeout"
            @unknown default: return "unknown_terminal"
            }
        }
    }
}

extension DistributedCBv2Engine {
    func observe(_ state: DistributedRequestState, phase: DistributedRequestObservation.Phase,
                 reason: CBv2FinishReason? = nil) {
        guard let observationSink else { return }
        observationSink.enqueue(.init(state: state, phase: phase, now: clock.now(), reason: reason))
    }
}
