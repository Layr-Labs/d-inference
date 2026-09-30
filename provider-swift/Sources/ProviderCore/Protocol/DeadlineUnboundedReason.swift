// Optional engine-supplied diagnostic; mirror: coordinator/protocol/profile_deadline_unbounded.go.
// No provider-side inference from occupancy, rates, or the remaining deadline.

public enum DeadlineUnboundedReason: String, ProfilerFoldingEnum {
    case unsupportedScheduler = "unsupported_scheduler"
    case targetMissing = "target_missing"
    case invalidInFlightAssignment = "invalid_in_flight_assignment"
    case inconsistentTokenCursor = "inconsistent_token_cursor"
    case unownedPendingSample = "unowned_pending_sample"
    case multimodalWork = "multimodal_work"
    case invalidPrefixReservation = "invalid_prefix_reservation"
    case invalidProjectionAssignment = "invalid_projection_assignment"
    case invalidProjectionTransition = "invalid_projection_transition"
    case projectionArithmetic = "projection_arithmetic"
    case chainedStepUnprojectable = "chained_step_unprojectable"
    case iterationLimit = "iteration_limit"
    case prefixGeometryBlocked = "prefix_geometry_blocked"
    case speculationBoundMissing = "speculation_bound_missing"
    case noSchedulingProgress = "no_scheduling_progress"
    case targetNotSampled = "target_not_sampled"
    case invalidWorkTotals = "invalid_work_totals"
    case capacityModelUnsupported = "capacity_model_unsupported"
    case capacityNotGuaranteed = "capacity_not_guaranteed"
    case prefillRateUnavailable = "prefill_rate_unavailable"
    case decodeRateUnavailable = "decode_rate_unavailable"
    case serviceDurationInvalid = "service_duration_invalid"
    case serviceDurationUnderflow = "service_duration_underflow"
    case other
}
