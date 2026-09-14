package settlement

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s Service) priceCompletion(providerID string, provider *registry.Provider, pr *registry.PendingRequest, msg *protocol.InferenceCompleteMessage) completionPrice {
	// Resolve the consumer once: platform-fee override (nil = global default)
	// and whether this is a wholesale/service channel (e.g. OpenRouter). A
	// failed lookup (raw API-key account with no user row) falls back to
	// defaults. Service accounts run on a 0% fee.
	var feePercent *int64
	isServiceConsumer := false
	settleStart := time.Now()
	if u, err := s.deps.Store().GetUserByAccountID(pr.ConsumerKey); err == nil && u != nil {
		feePercent = u.PlatformFeePercent
		isServiceConsumer = u.Role == store.RoleService
	}

	// Calculate cost. Direct consumers: provider custom price, then platform DB
	// price, then hardcoded defaults, with the per-request minimum applied.
	// Service/wholesale traffic is billed at the advertised platform price
	// (never a provider's higher custom price) and is exempt from the minimum,
	// so the debit matches the published per-token OpenRouter feed exactly.
	providerAccountForPricing := ""
	if p := s.deps.Providers().GetProvider(providerID); p != nil {
		providerAccountForPricing = providerPricingKey(p)
	}
	var customIn, customOut int64
	var hasCustom bool
	if !isServiceConsumer {
		customIn, customOut, hasCustom = s.deps.Store().GetModelPrice(providerAccountForPricing, pr.Model)
	}
	if !hasCustom {
		customIn, customOut, hasCustom = s.deps.Store().GetModelPrice("platform", pr.Model)
	}
	var totalCost int64
	if isServiceConsumer {
		totalCost = payments.CalculateCostWithOverridesNoMinimum(pr.Model, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, customIn, customOut, hasCustom)
	} else {
		totalCost = payments.CalculateCostWithOverrides(pr.Model, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, customIn, customOut, hasCustom)
	}

	providerPayout := payments.ProviderPayoutWithPercent(totalCost, feePercent)

	// Free settlement when an OWNED machine served the request. Two paths reach
	// here:
	//   - FreeSelfRoute (exclusive self-route): the router only ever picks owned
	//     providers, so a mismatch should be impossible (machine unlinked
	//     mid-flight); a mismatch falls back to paid to close the "mark free,
	//     serve elsewhere" hole.
	//   - PreferOwner (prefer-with-fallback): the request may legitimately have
	//     fallen back to a PUBLIC provider, in which case paid settlement is the
	//     correct, expected outcome — not an error.
	// Either way: free iff the provider that actually served it is owned by the
	// requesting account. Ownership is read from the serving provider object
	// (stable across deregistration), not a fresh lookup.
	freeSelfRoute := false
	if pr.FreeSelfRoute || pr.PreferOwner {
		serving := s.deps.Providers().GetProvider(providerID)
		if serving == nil {
			serving = provider
		}
		serving.Mu().Lock()
		servingOwner := serving.AccountID
		serving.Mu().Unlock()
		if servingOwner != "" && servingOwner == pr.ConsumerKey {
			// Owned machine served it → free. For PreferOwner this also fully
			// refunds the up-front reservation below (totalCost 0 < reserved).
			freeSelfRoute = true
			totalCost = 0
			providerPayout = 0
		} else if pr.FreeSelfRoute {
			// Exclusive self-route should never be served by a non-owned
			// provider — surface it and settle as paid (defense-in-depth).
			s.deps.Logger.Error("self-route completion served by a non-owned provider — settling as paid (defense-in-depth)",
				"provider_id", providerID,
				"request_id", msg.RequestID,
				"serving_owner", servingOwner,
				"consumer_key", pr.ConsumerKey,
			)
		}
		// PreferOwner served by a public provider is the normal fallback — no
		// log, settle as paid against the reservation.
	}

	return completionPrice{feePercent: feePercent, totalCost: totalCost, providerPayout: providerPayout, freeSelfRoute: freeSelfRoute, startedAt: settleStart}
}
