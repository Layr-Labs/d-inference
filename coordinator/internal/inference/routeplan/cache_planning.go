package routeplan

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachemetrics"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type CachePlanningInput struct {
	Account            string
	Model              string
	Body               []byte
	HasMedia           bool
	LoweringFailed     bool
	ReceivedAt         time.Time
	FirstContentBudget time.Duration
}

// CachePlanner binds optional cache planning to the inference owner's actual
// registry, prompt resources and observation sinks.
type CachePlanner struct {
	Registry    *registry.Registry
	Artifacts   *promptcontract.Provisioner
	Contract    *promptcontract.Client
	Preloader   *promptcontract.PreloadController
	Observation *observation.Owner
}

// PlanResult is the cache planning adapter. Production request memoization
// shares the result, including prompt counts, with preflight and dispatch.
func (p CachePlanner) PlanResult(ctx context.Context, input CachePlanningInput) registry.CachePlanResult {
	started := time.Now()
	modelLabel := p.ModelLabel(input.Model)
	reason := CachePlanningUnknownOutcome
	defer func() { p.EmitDecision(modelLabel, reason, time.Since(started)) }()

	if input.LoweringFailed {
		reason = CachePlanningLoweringUnsupported
		return registry.CachePlanResult{}
	}
	if p.Artifacts == nil || p.Contract == nil || p.Preloader == nil {
		reason = CachePlanningDependenciesUnavailable
		return registry.CachePlanResult{}
	}
	status, ok := p.Artifacts.Status(input.Model)
	if artifactReason := CachePlanningArtifactReason(status, ok); artifactReason != "" {
		reason = artifactReason
		return registry.CachePlanResult{}
	}
	if !p.Preloader.ReadyFor(status.PromptContractID) {
		reason = CachePlanningPreloadNotReady
		return registry.CachePlanResult{}
	}

	// Preserve the original receipt-time budget, including exempt/zero-clock
	// behavior. Only optional planning receives this child, never dispatch.
	planningCtx, cancel := firstcontent.FirstTokenWriteContext(ctx, input.ReceivedAt, input.FirstContentBudget)
	defer cancel()
	result := p.Registry.PlanCacheRouteWithResult(planningCtx, p.Contract, registry.CachePlanInput{
		Account:              input.Account,
		Model:                input.Model,
		PromptContractID:     status.PromptContractID,
		ModelAggregateSHA256: status.ModelAggregateSHA256,
		Body:                 input.Body,
		HasMedia:             input.HasMedia,
	})
	// Registry still owns eligibility, sampling and outcome precedence. Keep
	// legacy accounting distinct from the broader API decision population.
	p.Observation.EmitExactCachePlan(result)
	reason = CachePlanningResultReason(result.Outcome)
	return result
}

// ModelLabel is the existing catalog-bounded model label. A caller alias or an
// unregistered model is reported as "unknown".
func (p CachePlanner) ModelLabel(model string) string {
	return cachemetrics.CacheModelLabel(p.Registry, model)
}

// An empty reason means the unchanged artifact prerequisites have passed.
// Error contents and artifact paths are never returned for metric labels.
func CachePlanningArtifactReason(status promptcontract.ProvisionStatus, exists bool) CachePlanningDecisionReason {
	if !exists {
		return CachePlanningArtifactMissing
	}
	if !status.ArtifactReady {
		if status.LastError != "" {
			return CachePlanningArtifactFailed
		}
		return CachePlanningArtifactPending
	}
	if status.PromptContractID == "" {
		return CachePlanningArtifactInvalid
	}
	return ""
}
