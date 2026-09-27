package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type cachePlanningInput struct {
	Account            string
	Model              string
	Body               []byte
	HasMedia           bool
	LoweringFailed     bool
	ReceivedAt         time.Time
	FirstContentBudget time.Duration
}

// planCacheRoute runs once after inference preflight. Retries and queued
// dispatch retain its plan and keep their existing independent attempt bindings.
func (s *Server) planCacheRoute(ctx context.Context, input cachePlanningInput) registry.CachePlan {
	started := time.Now()
	modelLabel := s.cacheModelLabel(input.Model)
	reason := cachePlanningUnknownOutcome
	defer func() { s.emitCachePlanningDecision(modelLabel, reason, time.Since(started)) }()

	if input.LoweringFailed {
		reason = cachePlanningLoweringUnsupported
		return registry.CachePlan{}
	}
	if s.promptArtifacts == nil || s.promptContract == nil || s.promptPreloader == nil {
		reason = cachePlanningDependenciesUnavailable
		return registry.CachePlan{}
	}
	status, ok := s.promptArtifacts.Status(input.Model)
	if artifactReason := cachePlanningArtifactReason(status, ok); artifactReason != "" {
		reason = artifactReason
		return registry.CachePlan{}
	}
	if !s.promptPreloader.ReadyFor(status.PromptContractID) {
		reason = cachePlanningPreloadNotReady
		return registry.CachePlan{}
	}

	// Preserve the original receipt-time budget, including exempt/zero-clock
	// behavior. Only optional planning receives this child, never dispatch.
	planningCtx, cancel := firstTokenWriteContext(ctx, input.ReceivedAt, input.FirstContentBudget)
	defer cancel()
	result := s.registry.PlanCacheRouteWithResult(planningCtx, s.promptContract, registry.CachePlanInput{
		Account:              input.Account,
		Model:                input.Model,
		PromptContractID:     status.PromptContractID,
		ModelAggregateSHA256: status.ModelAggregateSHA256,
		Body:                 input.Body,
		HasMedia:             input.HasMedia,
	})
	// Registry still owns eligibility, sampling and outcome precedence. Keep
	// legacy accounting distinct from the broader API decision population.
	s.emitExactCachePlan(result)
	reason = cachePlanningResultReason(result.Outcome)
	return result.Plan
}

// An empty reason means the unchanged artifact prerequisites have passed.
// Error contents and artifact paths are never returned for metric labels.
func cachePlanningArtifactReason(status promptcontract.ProvisionStatus, exists bool) cachePlanningDecisionReason {
	if !exists {
		return cachePlanningArtifactMissing
	}
	if !status.ArtifactReady {
		if status.LastError != "" {
			return cachePlanningArtifactFailed
		}
		return cachePlanningArtifactPending
	}
	if status.PromptContractID == "" {
		return cachePlanningArtifactInvalid
	}
	return ""
}
