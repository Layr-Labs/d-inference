package inference

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// planPromptRoute shares the existing renderer/tokenizer call with cache
// planning. Count-only accounting also works when cache routing is off; it does
// not enable cache participation, create cache keys, or wait for tokenizer load.
func (s *Owner) planPromptRoute(ctx context.Context, account, model string, body []byte, hasMedia, hasTools bool, estimate int) promptwork.Result {
	result := promptwork.Result{Work: promptwork.Heuristic(calibratedContextPromptTokens(model, estimate))}
	cachePlanner := s.NewCachePlanner()
	cacheInput := routeplan.CachePlanningInput{Account: account, Model: model, Body: body, HasMedia: hasMedia}
	// The two early returns call the planner only to record why this request
	// has no cache plan; they do not use its result.
	if hasMedia || s.promptArtifacts == nil || s.promptContract == nil || s.promptPreloader == nil {
		cachePlanner.PlanResult(ctx, cacheInput)
		return result
	}
	status, ok := s.promptArtifacts.Status(model)
	if !ok || !status.ArtifactReady || status.PromptContractID == "" {
		cachePlanner.PlanResult(ctx, cacheInput)
		return result
	}
	return promptwork.Account(ctx, s.promptWorkGate, len(body), result, func(ctx context.Context) promptwork.Result {
		if promptwork.HasCalibrations() {
			if shape, known := promptwork.ShapeFromBody(body); known {
				if work := promptwork.Calibrated(model, status.ModelAggregateSHA256, status.PromptContractID, estimate, hasTools, shape); work != nil {
					result.Work = work
				}
			}
		}
		planned := cachePlanner.PlanResult(ctx, cacheInput)
		if !planned.SidecarCalled && !s.promptPreloader.ReadyFor(status.PromptContractID) {
			return result
		}
		input := registry.CachePlanInput{
			Account: account, Model: model, PromptContractID: status.PromptContractID,
			ModelAggregateSHA256: status.ModelAggregateSHA256, Body: body, HasMedia: hasMedia,
		}
		return promptwork.Plan(ctx, s.promptContract, input, result.Work,
			func(ctx context.Context) registry.CachePlanResult {
				return planned
			})
	})
}
