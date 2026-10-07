package cacheactivation

// CachePlanOutcome is deliberately low-cardinality and privacy-safe so it can
// be used directly in operational metrics.
type CachePlanOutcome string

const (
	CachePlanOff          CachePlanOutcome = "off"
	CachePlanIneligible   CachePlanOutcome = "ineligible"
	CachePlanSampledOut   CachePlanOutcome = "sampled_out"
	CachePlanThrottled    CachePlanOutcome = "throttled"
	CachePlanColdOnly     CachePlanOutcome = "cold_only"
	CachePlanSidecarError CachePlanOutcome = "sidecar_error"
	CachePlanNoBoundaries CachePlanOutcome = "no_boundaries"
	CachePlanInvalid      CachePlanOutcome = "invalid_plan"
	CachePlanPlanned      CachePlanOutcome = "planned"
)
