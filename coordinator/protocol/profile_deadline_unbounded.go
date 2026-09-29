package protocol

// DeadlineUnboundedReason identifies the engine condition that prevented a
// finite admissible first-token projection. These are diagnostics, not routing
// inputs. Empty means an older engine supplied no reason; unknown values fold
// to other so no provider-supplied free text reaches stored profiles.
type DeadlineUnboundedReason string

const (
	DeadlineUnboundedUnsupportedScheduler        DeadlineUnboundedReason = "unsupported_scheduler"
	DeadlineUnboundedTargetMissing               DeadlineUnboundedReason = "target_missing"
	DeadlineUnboundedInvalidInFlightAssignment   DeadlineUnboundedReason = "invalid_in_flight_assignment"
	DeadlineUnboundedInconsistentTokenCursor     DeadlineUnboundedReason = "inconsistent_token_cursor"
	DeadlineUnboundedUnownedPendingSample        DeadlineUnboundedReason = "unowned_pending_sample"
	DeadlineUnboundedMultimodalWork              DeadlineUnboundedReason = "multimodal_work"
	DeadlineUnboundedInvalidPrefixReservation    DeadlineUnboundedReason = "invalid_prefix_reservation"
	DeadlineUnboundedInvalidProjectionAssignment DeadlineUnboundedReason = "invalid_projection_assignment"
	DeadlineUnboundedInvalidProjectionTransition DeadlineUnboundedReason = "invalid_projection_transition"
	DeadlineUnboundedProjectionArithmetic        DeadlineUnboundedReason = "projection_arithmetic"
	DeadlineUnboundedChainedStepUnprojectable    DeadlineUnboundedReason = "chained_step_unprojectable"
	DeadlineUnboundedIterationLimit              DeadlineUnboundedReason = "iteration_limit"
	DeadlineUnboundedPrefixGeometryBlocked       DeadlineUnboundedReason = "prefix_geometry_blocked"
	DeadlineUnboundedSpeculationBoundMissing     DeadlineUnboundedReason = "speculation_bound_missing"
	DeadlineUnboundedNoSchedulingProgress        DeadlineUnboundedReason = "no_scheduling_progress"
	DeadlineUnboundedTargetNotSampled            DeadlineUnboundedReason = "target_not_sampled"
	DeadlineUnboundedInvalidWorkTotals           DeadlineUnboundedReason = "invalid_work_totals"
	DeadlineUnboundedCapacityModelUnsupported    DeadlineUnboundedReason = "capacity_model_unsupported"
	DeadlineUnboundedCapacityNotGuaranteed       DeadlineUnboundedReason = "capacity_not_guaranteed"
	DeadlineUnboundedPrefillRateUnavailable      DeadlineUnboundedReason = "prefill_rate_unavailable"
	DeadlineUnboundedDecodeRateUnavailable       DeadlineUnboundedReason = "decode_rate_unavailable"
	DeadlineUnboundedServiceDurationInvalid      DeadlineUnboundedReason = "service_duration_invalid"
	DeadlineUnboundedServiceDurationUnderflow    DeadlineUnboundedReason = "service_duration_underflow"
	DeadlineUnboundedOther                       DeadlineUnboundedReason = "other"
)

func (v DeadlineUnboundedReason) Valid() bool {
	switch v {
	case DeadlineUnboundedUnsupportedScheduler,
		DeadlineUnboundedTargetMissing,
		DeadlineUnboundedInvalidInFlightAssignment,
		DeadlineUnboundedInconsistentTokenCursor,
		DeadlineUnboundedUnownedPendingSample,
		DeadlineUnboundedMultimodalWork,
		DeadlineUnboundedInvalidPrefixReservation,
		DeadlineUnboundedInvalidProjectionAssignment,
		DeadlineUnboundedInvalidProjectionTransition,
		DeadlineUnboundedProjectionArithmetic,
		DeadlineUnboundedChainedStepUnprojectable,
		DeadlineUnboundedIterationLimit,
		DeadlineUnboundedPrefixGeometryBlocked,
		DeadlineUnboundedSpeculationBoundMissing,
		DeadlineUnboundedNoSchedulingProgress,
		DeadlineUnboundedTargetNotSampled,
		DeadlineUnboundedInvalidWorkTotals,
		DeadlineUnboundedCapacityModelUnsupported,
		DeadlineUnboundedCapacityNotGuaranteed,
		DeadlineUnboundedPrefillRateUnavailable,
		DeadlineUnboundedDecodeRateUnavailable,
		DeadlineUnboundedServiceDurationInvalid,
		DeadlineUnboundedServiceDurationUnderflow,
		DeadlineUnboundedOther:
		return true
	}
	return false
}

func (v DeadlineUnboundedReason) Fold() DeadlineUnboundedReason {
	return foldEnum(v, DeadlineUnboundedOther)
}
