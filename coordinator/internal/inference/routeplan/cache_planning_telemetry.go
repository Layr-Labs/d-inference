package routeplan

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachemetrics"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type CachePlanningDecisionReason string

const (
	CachePlanningLoweringUnsupported     CachePlanningDecisionReason = "lowering_unsupported"
	CachePlanningDependenciesUnavailable CachePlanningDecisionReason = "dependencies_unavailable"
	CachePlanningArtifactMissing         CachePlanningDecisionReason = "artifact_missing"
	CachePlanningArtifactPending         CachePlanningDecisionReason = "artifact_pending"
	CachePlanningArtifactFailed          CachePlanningDecisionReason = "artifact_failed"
	CachePlanningArtifactInvalid         CachePlanningDecisionReason = "artifact_invalid"
	CachePlanningPreloadNotReady         CachePlanningDecisionReason = "preload_not_ready"
	CachePlanningOff                     CachePlanningDecisionReason = "off"
	CachePlanningIneligible              CachePlanningDecisionReason = "ineligible"
	CachePlanningSampledOut              CachePlanningDecisionReason = "sampled_out"
	CachePlanningThrottled               CachePlanningDecisionReason = "throttled"
	CachePlanningColdOnly                CachePlanningDecisionReason = "cold_only"
	CachePlanningSidecarError            CachePlanningDecisionReason = "sidecar_error"
	CachePlanningNoBoundaries            CachePlanningDecisionReason = "no_boundaries"
	CachePlanningInvalidPlan             CachePlanningDecisionReason = "invalid_plan"
	CachePlanningPlanned                 CachePlanningDecisionReason = "planned"
	CachePlanningUnknownOutcome          CachePlanningDecisionReason = "unknown_outcome"
)

func CachePlanningResultReason(outcome registry.CachePlanOutcome) CachePlanningDecisionReason {
	switch outcome {
	case registry.CachePlanOff:
		return CachePlanningOff
	case registry.CachePlanIneligible:
		return CachePlanningIneligible
	case registry.CachePlanSampledOut:
		return CachePlanningSampledOut
	case registry.CachePlanThrottled:
		return CachePlanningThrottled
	case registry.CachePlanColdOnly:
		return CachePlanningColdOnly
	case registry.CachePlanSidecarError:
		return CachePlanningSidecarError
	case registry.CachePlanNoBoundaries:
		return CachePlanningNoBoundaries
	case registry.CachePlanInvalid:
		return CachePlanningInvalidPlan
	case registry.CachePlanPlanned:
		return CachePlanningPlanned
	default:
		return CachePlanningUnknownOutcome
	}
}

func BoundedCachePlanningReason(reason CachePlanningDecisionReason) string {
	switch reason {
	case CachePlanningLoweringUnsupported, CachePlanningDependenciesUnavailable,
		CachePlanningArtifactMissing, CachePlanningArtifactPending, CachePlanningArtifactFailed,
		CachePlanningArtifactInvalid, CachePlanningPreloadNotReady, CachePlanningOff,
		CachePlanningIneligible, CachePlanningSampledOut, CachePlanningThrottled,
		CachePlanningColdOnly, CachePlanningSidecarError, CachePlanningNoBoundaries,
		CachePlanningInvalidPlan, CachePlanningPlanned, CachePlanningUnknownOutcome:
		return string(reason)
	default:
		return string(CachePlanningUnknownOutcome)
	}
}

// The caller captures the existing catalog-bounded model label once. Latency
// covers helper work (including early returns), not end-to-end inference.
func (p CachePlanner) EmitDecision(modelLabel string, reason CachePlanningDecisionReason, elapsed time.Duration) {
	value := BoundedCachePlanningReason(reason)
	if elapsed < 0 {
		elapsed = 0
	}
	latencyMs := float64(elapsed) / float64(time.Millisecond)
	label := observation.MetricLabel{Name: "reason", Value: value}
	metrics := p.Observation.Metrics()
	if metrics != nil {
		metrics.IncCounter("exact_cache_planning_decision_total", label)
		metrics.ObserveHistogram("exact_cache_planning_decision_latency_ms", latencyMs, label)
	}
	tags := []string{"reason:" + value}
	p.Observation.Incr("exact_cache.planning_decision", tags)
	p.Observation.Histogram("exact_cache.planning_decision_latency_ms", latencyMs, tags)
	// The per-model mirror uses the shared catalog-bounded cache-model policy.
	var modelMetrics cachemetrics.CacheMetricRegistry
	if metrics != nil {
		modelMetrics = metrics
	}
	model := observation.MetricLabel{Name: "model", Value: modelLabel}
	cachemetrics.CacheModelCount(modelMetrics, p.Observation.Count, "planning_decision", 1, model, label)
	cachemetrics.CacheModelTiming(modelMetrics, p.Observation.Count, "planning_decision_latency", latencyMs, model, label)
}
