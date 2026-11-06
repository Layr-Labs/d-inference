import Logging

extension DistributedRequestObservation {
    /// The normal distributed serving factory emits a bounded set of local log
    /// records. This does not change the coordinator telemetry wire vocabulary.
    static func log(_ observation: Self) {
        let logger = Logger(label: "darkbloom.distributed.request")
        var fields: Logger.Metadata = [
            "generation": .string(observation.generation.uuidString),
            "phase": .string(observation.phase.rawValue),
            "prompt_tokens": .stringConvertible(observation.promptTokens),
            "completion_tokens": .stringConvertible(observation.completionTokens),
            "admission_elapsed_ms": .stringConvertible(observation.admissionElapsedMilliseconds),
            "reservation_ms": .stringConvertible(observation.reservationMilliseconds),
        ]
        if let remaining = observation.remainingFirstTokenMilliseconds {
            fields["remaining_first_token_ms"] = .stringConvertible(remaining)
        }
        if let outcome = observation.outcome { fields["outcome"] = .string(outcome) }
        logger.info("Distributed request lifecycle", metadata: fields)
    }
}
