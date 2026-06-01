package registry

import (
	"time"
)

// providerEligibleLocked runs the provider-level structural routing gates
// (caller holds p.mu): the provider must be online+trusted, meet the minimum
// trust level, be runtime-verified, support private text, and have a fresh
// attestation challenge. It is model-independent — callers that route a
// specific model additionally require providerServesCatalogModelLocked (see
// providerRoutableLocked). It does NOT check capacity/headroom or slot state.
func (r *Registry) providerEligibleLocked(p *Provider, now time.Time) bool {
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
		return false
	}
	if !p.RuntimeVerified {
		return false
	}
	if !providerSupportsPrivateTextLocked(p) {
		return false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	return true
}

// providerRoutableLocked reports whether p passes every structural routing gate
// for model (caller holds p.mu): the provider-level gates of
// providerEligibleLocked plus serving model from the active catalog. It does
// NOT check capacity/headroom or slot state; callers that distinguish
// structural vs capacity rejection apply those separately.
func (r *Registry) providerRoutableLocked(p *Provider, model string, now time.Time) bool {
	return r.providerEligibleLocked(p, now) && r.providerServesCatalogModelLocked(p, model)
}

// freeMemoryAdmits returns true when the provider has enough headroom.
// Providers that report a token budget use budget-based admission;
// legacy providers fall back to memory-based estimation.
func freeMemoryAdmits(snap routingSnapshot, reqPromptTokens, reqMaxTokens int) bool {
	if snap.activeTokenBudgetMax > 0 {
		requestTokens := int64(reqPromptTokens) + int64(reqMaxTokens)
		// Include coordinator-side pending tokens not yet reflected in the
		// provider's heartbeat. Avoid double-counting active/queued backend
		// budgets that are still present in the coordinator pending set until
		// completion/cancellation removes them.
		coordinatorExtra := int64(snap.pendingMaxTokens) - committedTokenBudget(snap)
		if coordinatorExtra < 0 {
			coordinatorExtra = 0
		}
		return snap.activeTokenBudgetUsed+snap.queuedTokenBudget+coordinatorExtra+requestTokens <= snap.activeTokenBudgetMax
	}

	if snap.modelSizeGB <= 0 || snap.totalMemoryGB <= 0 {
		return true
	}
	required := snap.modelSizeGB
	if snap.modelLoaded {
		required = 0
	}
	tokens := int64(reqPromptTokens) + int64(reqMaxTokens)
	if tokens < 0 {
		tokens = 0
	}
	const maxTokensForCalc = 16 << 20
	if tokens > maxTokensForCalc {
		tokens = maxTokensForCalc
	}
	kvCacheGB := float64(tokens*kvCacheBytesPerToken) / float64(bytesPerGB)
	required += kvCacheGB

	// When the model is available on disk but not currently loaded, the
	// provider will evict idle models to make room (LRU eviction). Check
	// whether the model individually fits in total memory (with OS/KV
	// overhead) rather than requiring it to fit alongside existing loaded
	// models. The provider handles the swap autonomously.
	//
	// However, if the provider has in-flight requests (totalPending > 0),
	// it cannot evict the currently-serving model. In that case, fall
	// through to the standard free-memory check which requires room
	// alongside active models.
	if snap.availableOnDisk && !snap.modelLoaded && snap.totalPending == 0 {
		const osReserveGB = 4.0
		return snap.modelSizeGB+kvCacheGB+osReserveGB <= snap.totalMemoryGB
	}

	free := snap.totalMemoryGB - snap.gpuMemoryActiveGB
	return free >= required
}

func pendingTokenBudget(pr *PendingRequest) int {
	if pr == nil {
		return 0
	}
	prompt := pr.EstimatedPromptTokens
	if prompt < 0 {
		prompt = 0
	}
	maxTok := pr.RequestedMaxTokens
	if maxTok <= 0 {
		maxTok = defaultRequestedMaxTokens
	}
	return prompt + maxTok
}

func committedTokenBudget(snap routingSnapshot) int64 {
	committed := snap.activeTokenBudgetUsed + snap.queuedTokenBudget
	if snap.maxTokensPotential > committed {
		committed = snap.maxTokensPotential
	}
	if committed < 0 {
		return 0
	}
	return committed
}

func (r *Registry) providerCanAdmitLocked(p *Provider, model string) bool {
	if !r.providerRoutableLocked(p, model, time.Now()) {
		return false
	}
	if !p.hasConcurrencyHeadroomForModelLocked(model) {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			switch slot.State {
			case "crashed", "reloading":
				return false
			}
			break
		}
	}
	return true
}
