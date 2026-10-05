package routeplan

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (p CachePlanner) cachePreloadIdentity(model string, status promptcontract.ProvisionStatus) (promptcontract.PreloadDemandIdentity, bool) {
	_, verified := p.Artifacts.VerifiedPreloadArtifacts()
	for _, identity := range verified {
		if identity.ModelID == model && identity.ModelAggregateSHA256 == status.ModelAggregateSHA256 &&
			identity.PromptContractID == status.PromptContractID {
			return identity, true
		}
	}
	return promptcontract.PreloadDemandIdentity{}, false
}

func CachePreloadDemandWithinDeadline(ctx context.Context, input CachePlanningInput) bool {
	return ctx.Err() == nil && (input.ReceivedAt.IsZero() || input.FirstContentBudget <= 0 ||
		time.Now().Before(input.ReceivedAt.Add(input.FirstContentBudget)))
}

// commitCachePlanning is a bounded second observation, never a retry loop.
// A prior rejection cannot be promoted to Plan if policy changes to allowed.
// Native acknowledgement is a diagnostic prerequisite; only exact current
// participation can reach the Registry's independent activation/Plan gate.
func (p CachePlanner) commitCachePlanning(
	ctx context.Context, input CachePlanningInput, planInput registry.CachePlanInput,
	identity promptcontract.PreloadDemandIdentity, initialRejected bool,
	observed promptcontract.PreloadPlanningState,
) (registry.CachePlanResult, bool) {
	if !observed.Acknowledged {
		return registry.CachePlanResult{}, false
	}
	current := p.Preloader.PlanningState(identity)
	if !current.Acknowledged {
		return registry.CachePlanResult{}, false
	}
	if rejection, rejected := p.Registry.CachePlanRejection(p.Contract, planInput); rejected {
		return rejection, true
	}
	if initialRejected || !observed.Participating || !current.Participating {
		return registry.CachePlanResult{}, false
	}
	planningCtx, cancel := firstcontent.FirstTokenWriteContext(ctx, input.ReceivedAt, input.FirstContentBudget)
	defer cancel()
	return p.Registry.PlanCacheRouteWithResult(planningCtx, p.Contract, planInput), true
}
