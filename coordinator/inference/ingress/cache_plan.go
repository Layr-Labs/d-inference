package ingress

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Controller) planCacheRoute(
	ctx context.Context,
	account, model string,
	body []byte,
	hasMedia bool,
) registry.CachePlan {
	if s.deps.PromptArtifacts() == nil || s.deps.PromptContract() == nil || s.deps.PromptPreloader() == nil {
		return registry.CachePlan{}
	}
	status, ok := s.deps.PromptArtifacts().Status(model)
	if !ok || !status.ArtifactReady || status.PromptContractID == "" {
		return registry.CachePlan{}
	}
	if !s.deps.PromptPreloader().ReadyFor(status.PromptContractID) {
		return registry.CachePlan{}
	}
	result := s.deps.Registry().PlanCacheRouteWithResult(ctx, s.deps.PromptContract(), registry.CachePlanInput{
		Account:              account,
		Model:                model,
		PromptContractID:     status.PromptContractID,
		ModelAggregateSHA256: status.ModelAggregateSHA256,
		Body:                 body,
		HasMedia:             hasMedia,
	})
	s.deps.Observer.ExactCachePlan(result)
	return result.Plan
}
