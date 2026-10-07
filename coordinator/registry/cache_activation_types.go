package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"

// Existing caller-facing outcome and status types retain their identities while
// the activation component owns sampling, throttling and outcome accounting.
type CachePlanOutcome = cacheactivation.CachePlanOutcome
type CacheRoutingActivationStatus = cacheactivation.CacheRoutingActivationStatus

const (
	CachePlanOff          = cacheactivation.CachePlanOff
	CachePlanIneligible   = cacheactivation.CachePlanIneligible
	CachePlanSampledOut   = cacheactivation.CachePlanSampledOut
	CachePlanThrottled    = cacheactivation.CachePlanThrottled
	CachePlanColdOnly     = cacheactivation.CachePlanColdOnly
	CachePlanSidecarError = cacheactivation.CachePlanSidecarError
	CachePlanNoBoundaries = cacheactivation.CachePlanNoBoundaries
	CachePlanInvalid      = cacheactivation.CachePlanInvalid
	CachePlanPlanned      = cacheactivation.CachePlanPlanned
)
