package inference

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// enterCacheFunnel decides funnel membership once, before planning: a text
// request for a catalog model while cache routing is on. Nil means outside.
func (s *Owner) enterCacheFunnel(model string, hasMedia bool) *cachefunnel.Request {
	if hasMedia || !s.registry.CacheRoutingCoversModel(model) {
		return nil
	}
	return s.cacheFunnel.Enter()
}

// closeCacheFunnel treats only a cancelled request context as the client
// leaving; an expired deadline is a failure, not a cancellation.
func closeCacheFunnel(ctx context.Context, request *cachefunnel.Request) {
	request.Close(errors.Is(ctx.Err(), context.Canceled))
}

// noteDispatchedCachePlanning records the planning outcome for the model and
// body the request is dispatched with. That one memoized result is the
// authority: decisions made for other candidate models or rewritten bodies
// during admission never reach the funnel. A result the work gate deferred
// carries no decision, and is the only place that refusal becomes visible.
func noteDispatchedCachePlanning(request *cachefunnel.Request, planned promptwork.Result) {
	if request == nil {
		return
	}
	if planned.PlanningDeferred() {
		request.NotePlanning(cachefunnel.PlanningGateRefused, cachefunnel.Tokens{})
		return
	}
	request.NotePlanning(planned.CachePlanning, planned.CountedPromptTokens)
	if planned.Cache.Present() {
		request.NotePlan(planned.Cache.PromptTokenCount, planned.Cache.RepeatedPrefixTokens)
	}
}

// cacheFunnelCompletion reads reuse from validated provider usage only.
// Absent or rejected cache usage stays unknown instead of becoming zero.
func cacheFunnelCompletion(usage protocol.UsageInfo, usageValid bool) cachefunnel.Completion {
	if !usageValid {
		return cachefunnel.Completion{}
	}
	return cachefunnel.Completion{
		Lookup: cachefunnel.LookupFromUsageOutcome(usage.CacheOutcome),
		Reused: cachefunnel.KnownTokens(usage.CachedTokens),
	}
}
