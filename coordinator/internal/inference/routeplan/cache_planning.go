package routeplan

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
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
	// PreloadPlanning, when set, answers planning's demand and observation
	// calls in place of Preloader, which it must wrap. Nil uses Preloader.
	PreloadPlanning PreloadPlanning
}

// CachePlanDecision is one planning call's registry result together with the
// decision reason emitted for it.
type CachePlanDecision struct {
	registry.CachePlanResult
	Reason CachePlanningDecisionReason
}

// PlanResult is the cache planning adapter. Production request memoization
// shares the result, including prompt counts, with preflight and dispatch.
func (p CachePlanner) PlanResult(ctx context.Context, input CachePlanningInput) (decision CachePlanDecision) {
	started := time.Now()
	modelLabel := p.ModelLabel(input.Model)
	decision.Reason = CachePlanningUnknownOutcome
	defer func() { p.EmitDecision(modelLabel, decision.Reason, time.Since(started)) }()

	if input.LoweringFailed {
		decision.Reason = CachePlanningLoweringUnsupported
		return decision
	}
	if p.Artifacts == nil || p.Contract == nil || p.Preloader == nil {
		decision.Reason = CachePlanningDependenciesUnavailable
		return decision
	}
	status, ok := p.Artifacts.Status(input.Model)
	if artifactReason := CachePlanningArtifactReason(status, ok); artifactReason != "" {
		decision.Reason = artifactReason
		return decision
	}
	identity, verified := p.cachePreloadIdentity(input.Model, status)
	if !verified {
		decision.Reason = CachePlanningPreloadNotReady
		return decision
	}
	planInput := registry.CachePlanInput{
		Account:              input.Account,
		Model:                input.Model,
		PromptContractID:     status.PromptContractID,
		ModelAggregateSHA256: status.ModelAggregateSHA256,
		Body:                 input.Body,
		HasMedia:             input.HasMedia,
	}
	preload := p.preloadPlanning()
	_, rejected := p.Registry.CachePlanRejection(p.Contract, planInput)
	if !rejected && CachePreloadDemandWithinDeadline(ctx, input) {
		// Once per memoized authenticated candidate body, before the
		// readiness gate. No QPS/sample debit, waiting, or request data retention.
		preload.NoteDemand(identity)
	}
	state := preload.PlanningState(identity)
	result, decided := p.commitCachePlanning(ctx, input, planInput, identity, rejected, state)
	if !decided {
		decision.Reason = CachePlanningPreloadNotReady
		return decision
	}
	// Registry still owns eligibility, sampling and outcome precedence. Keep
	// legacy accounting distinct from the broader API decision population.
	p.Observation.EmitExactCachePlan(result)
	decision.CachePlanResult, decision.Reason = result, CachePlanningResultReason(result.Outcome)
	return decision
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
