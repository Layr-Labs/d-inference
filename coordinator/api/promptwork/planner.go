package promptwork

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Tokenizer interface {
	Plan(context.Context, promptcontract.PlanInput) (promptcontract.Plan, error)
}

// Plan reuses validated cache accounting when available. A count-only request
// shares the existing tokenizer transport but creates no cache participation.
// Failed sidecar calls are never retried on the remaining request clock.
// The caller must already hold Account's bounded work permit and context.
func Plan(ctx context.Context, client Tokenizer, input registry.CachePlanInput,
	fallback *protocol.PromptWork, cache func(context.Context) registry.CachePlanResult) Result {
	result := Result{Work: fallback}
	if ctx.Err() != nil {
		return result
	}
	planned := cache(ctx)
	result.Cache = planned.Plan
	if planned.PromptWork != nil {
		result.Work = planned.PromptWork
		return result
	}
	if planned.SidecarCalled || ctx.Err() != nil {
		return result
	}
	plan, err := client.Plan(ctx, promptcontract.PlanInput{
		PromptContractID: input.PromptContractID,
		// Boundaries are discarded. This count-only scope grants no cache reuse and
		// supplies no account identity to the tokenizer.
		ScopeID: "first-content-accounting", Endpoint: promptcontract.EndpointChatCompletions, Body: input.Body,
	})
	if err == nil && plan.PromptContractID == input.PromptContractID {
		if work := Exact(plan, input.ModelAggregateSHA256); work != nil {
			result.Work = work
		}
	}
	return result
}
