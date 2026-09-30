package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) cachePreloadSelection(verified []promptcontract.VerifiedPreloadArtifact, refreshAvailability bool) ([]promptcontract.PreloadDemandIdentity, []string) {
	admissible := s.registry.CachePreloadIdentities(verified)
	if !refreshAvailability || len(admissible) == 0 {
		return admissible, nil
	}
	public := make(map[string]bool)
	for _, model := range s.registry.ListModels() {
		public[model.ID] = true
	}
	var available []string
	for _, artifact := range verified {
		if public[artifact.ModelID] {
			available = append(available, artifact.ModelID)
		}
	}
	return admissible, available
}

func (s *Server) cachePreloadIdentity(model string, status promptcontract.ProvisionStatus) (promptcontract.PreloadDemandIdentity, bool) {
	_, verified := s.promptArtifacts.VerifiedPreloadArtifacts()
	for _, identity := range verified {
		if identity.ModelID == model && identity.ModelAggregateSHA256 == status.ModelAggregateSHA256 &&
			identity.PromptContractID == status.PromptContractID {
			return identity, true
		}
	}
	return promptcontract.PreloadDemandIdentity{}, false
}

func cachePreloadDemandWithinDeadline(ctx context.Context, input cachePlanningInput) bool {
	return ctx.Err() == nil && (input.ReceivedAt.IsZero() || input.FirstContentBudget <= 0 ||
		time.Now().Before(input.ReceivedAt.Add(input.FirstContentBudget)))
}

// commitCachePlanning is a bounded second observation, never a retry loop.
// A prior rejection cannot be promoted to Plan if policy changes to allowed.
// Native acknowledgement is a diagnostic prerequisite; only exact current
// participation can reach the Registry's independent activation/Plan gate.
func (s *Server) commitCachePlanning(
	ctx context.Context, input cachePlanningInput, planInput registry.CachePlanInput,
	identity promptcontract.PreloadDemandIdentity, initialRejected bool,
	observed promptcontract.PreloadPlanningState,
) (registry.CachePlanResult, bool) {
	if !observed.Acknowledged {
		return registry.CachePlanResult{}, false
	}
	current := s.promptPreloader.PlanningState(identity)
	if !current.Acknowledged {
		return registry.CachePlanResult{}, false
	}
	if rejection, rejected := s.registry.CachePlanRejection(s.promptContract, planInput); rejected {
		return rejection, true
	}
	if initialRejected || !observed.Participating || !current.Participating {
		return registry.CachePlanResult{}, false
	}
	planningCtx, cancel := firstTokenWriteContext(ctx, input.ReceivedAt, input.FirstContentBudget)
	defer cancel()
	return s.registry.PlanCacheRouteWithResult(planningCtx, s.promptContract, planInput), true
}
