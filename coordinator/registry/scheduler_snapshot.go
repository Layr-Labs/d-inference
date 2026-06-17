package registry

import "time"

// snapshotProviderLocked builds a routing snapshot for p, returning ok=false
// when p fails any structural/privacy/capacity/trait gate. selfRouteOwner is
// true when this is a self-route request and p is owned by the requesting
// account. It (1) drops the hardware-trust floor to TrustNone — a personal Mac
// will not be MDM/MDA enrolled, so without this it would be unroutable to its
// own owner — and (2) admits a private-only machine, which is otherwise
// excluded from the public fleet. Every privacy-critical gate (RuntimeVerified,
// private-text support, challenge freshness) still applies, so plaintext is
// never exposed and only the genuinely-signed provider binary serves. traits
// carry the request shape into the shape-keyed inference-error cooldown and the
// render-broken / version-floor eligibility gates.
func (r *Registry) snapshotProviderLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool) (routingSnapshot, bool) {
	now := time.Now()

	p.mu.Lock()
	defer p.mu.Unlock()

	if !r.providerPassesRoutingGatesLocked(p, model, traits, selfRouteOwner, now) {
		return routingSnapshot{}, false
	}

	snap := routingSnapshot{
		provider:      p,
		model:         model,
		slotState:     "unknown",
		totalPending:  p.pendingCount(),
		systemMetrics: p.SystemMetrics,
		decodeTPS:     resolvedDecodeTPS(p),
		prefillTPS:    resolvedPrefillTPS(p),
		totalMemoryGB: float64(p.Hardware.MemoryGB),
		modelSizeGB:   r.catalogSizeGBLocked(model),
		minRAMGb:      r.catalogMinRAMGbLocked(model),
	}

	for _, pr := range p.pendingReqs {
		if pr.Model != model {
			continue
		}
		snap.pendingForModel++
		snap.pendingMaxTokens += pendingTokenBudget(pr)
	}
	snap.hasHeadroom = p.hasConcurrencyHeadroomForModelLocked(model)
	snap.hasBackendCapacity = p.BackendCapacity != nil

	if p.BackendCapacity != nil {
		snap.gpuMemoryActiveGB = p.BackendCapacity.GPUMemoryActiveGB
		if p.BackendCapacity.TotalMemoryGB > 0 {
			snap.totalMemoryGB = p.BackendCapacity.TotalMemoryGB
		}
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			snap.slotState = slot.State
			snap.backendRunning = int(slot.NumRunning)
			snap.backendWaiting = int(slot.NumWaiting)
			snap.maxTokensPotential = slot.MaxTokensPotential
			snap.observedDecodeTPS = slot.ObservedDecodeTPS
			snap.observedPrefillTPS = slot.ObservedPrefillTPS
			snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
			snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
			snap.queuedTokenBudget = slot.QueuedTokenBudget
			break
		}
	}
	snap.modelLoaded = slotStateModelLoaded(snap.slotState)
	snap.availableOnDisk = !snap.modelLoaded
	snap.fleetMedianTPS = r.tpsRegistry.Median(model, p.Hardware.ChipFamily)

	return snap, true
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
