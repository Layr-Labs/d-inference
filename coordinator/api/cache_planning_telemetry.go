package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

type cachePlanningDecisionReason string

const (
	cachePlanningLoweringUnsupported     cachePlanningDecisionReason = "lowering_unsupported"
	cachePlanningDependenciesUnavailable cachePlanningDecisionReason = "dependencies_unavailable"
	cachePlanningArtifactMissing         cachePlanningDecisionReason = "artifact_missing"
	cachePlanningArtifactPending         cachePlanningDecisionReason = "artifact_pending"
	cachePlanningArtifactFailed          cachePlanningDecisionReason = "artifact_failed"
	cachePlanningArtifactInvalid         cachePlanningDecisionReason = "artifact_invalid"
	cachePlanningPreloadNotReady         cachePlanningDecisionReason = "preload_not_ready"
	cachePlanningOff                     cachePlanningDecisionReason = "off"
	cachePlanningIneligible              cachePlanningDecisionReason = "ineligible"
	cachePlanningSampledOut              cachePlanningDecisionReason = "sampled_out"
	cachePlanningThrottled               cachePlanningDecisionReason = "throttled"
	cachePlanningColdOnly                cachePlanningDecisionReason = "cold_only"
	cachePlanningSidecarError            cachePlanningDecisionReason = "sidecar_error"
	cachePlanningNoBoundaries            cachePlanningDecisionReason = "no_boundaries"
	cachePlanningInvalidPlan             cachePlanningDecisionReason = "invalid_plan"
	cachePlanningPlanned                 cachePlanningDecisionReason = "planned"
	cachePlanningUnknownOutcome          cachePlanningDecisionReason = "unknown_outcome"
)

func cachePlanningResultReason(outcome registry.CachePlanOutcome) cachePlanningDecisionReason {
	switch outcome {
	case registry.CachePlanOff:
		return cachePlanningOff
	case registry.CachePlanIneligible:
		return cachePlanningIneligible
	case registry.CachePlanSampledOut:
		return cachePlanningSampledOut
	case registry.CachePlanThrottled:
		return cachePlanningThrottled
	case registry.CachePlanColdOnly:
		return cachePlanningColdOnly
	case registry.CachePlanSidecarError:
		return cachePlanningSidecarError
	case registry.CachePlanNoBoundaries:
		return cachePlanningNoBoundaries
	case registry.CachePlanInvalid:
		return cachePlanningInvalidPlan
	case registry.CachePlanPlanned:
		return cachePlanningPlanned
	default:
		return cachePlanningUnknownOutcome
	}
}

func boundedCachePlanningReason(reason cachePlanningDecisionReason) string {
	switch reason {
	case cachePlanningLoweringUnsupported, cachePlanningDependenciesUnavailable,
		cachePlanningArtifactMissing, cachePlanningArtifactPending, cachePlanningArtifactFailed,
		cachePlanningArtifactInvalid, cachePlanningPreloadNotReady, cachePlanningOff,
		cachePlanningIneligible, cachePlanningSampledOut, cachePlanningThrottled,
		cachePlanningColdOnly, cachePlanningSidecarError, cachePlanningNoBoundaries,
		cachePlanningInvalidPlan, cachePlanningPlanned, cachePlanningUnknownOutcome:
		return string(reason)
	default:
		return string(cachePlanningUnknownOutcome)
	}
}

// The caller captures the existing catalog-bounded model label once. Latency
// covers helper work (including early returns), not end-to-end inference.
func (s *Server) emitCachePlanningDecision(modelLabel string, reason cachePlanningDecisionReason, elapsed time.Duration) {
	value := boundedCachePlanningReason(reason)
	if elapsed < 0 {
		elapsed = 0
	}
	latencyMs := float64(elapsed) / float64(time.Millisecond)
	label := MetricLabel{"reason", value}
	if s.metrics != nil {
		s.metrics.IncCounter("exact_cache_planning_decision_total", label)
		s.metrics.ObserveHistogram("exact_cache_planning_decision_latency_ms", latencyMs, label)
	}
	tags := []string{"reason:" + value}
	s.ddIncr("exact_cache.planning_decision", tags)
	s.ddHistogram("exact_cache.planning_decision_latency_ms", latencyMs, tags)
	s.cacheModelCount("planning_decision", 1, MetricLabel{"model", modelLabel}, label)
	s.cacheModelTiming("planning_decision_latency", latencyMs, MetricLabel{"model", modelLabel}, label)
}
