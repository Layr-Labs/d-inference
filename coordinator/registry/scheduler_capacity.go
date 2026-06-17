package registry

import "time"

// providerCanAdmitLocked is the under-the-provider-lock admit re-check run in
// ReserveProviderEx after a winner is selected: it re-applies every routing
// gate (via the shared providerPassesRoutingGatesLocked — same catalog, trust,
// privacy, challenge, shape-keyed inference-error cooldown, and trait gates as
// selection) plus the admit-specific capacity gates (concurrency headroom and
// non-crashed/non-reloading slot state). This guards the race where the
// provider's state changed between snapshot and reservation. Caller holds r.mu
// and p.mu.
func (r *Registry) providerCanAdmitLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool) bool {
	now := time.Now()
	if !r.providerPassesRoutingGatesLocked(p, model, traits, selfRouteOwner, now) {
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

// QuickCapacityCheck performs a fast, read-only scan of the provider fleet to
// determine whether any provider could serve a request for the given model
// right now. It runs the SAME per-provider gates as the full routing path —
// via the shared providerPassesRoutingGatesLocked (status, trust, runtime,
// privacy, challenge freshness, dispatch-load + shape-keyed inference-error
// cooldowns, and the trait gates: render-broken fences every shape, the tools
// version floor fences tool requests) — plus the capacity gates (concurrency
// headroom, slot state, free memory) but does NOT reserve capacity or create
// pending requests. traits carry the request shape so the preflight excludes a
// provider for exactly the reasons routing would, instead of reporting phantom
// capacity that routing then refuses (the drift this consolidation closes).
//
// Returns:
//   - candidateCount: providers that passed ALL gates (could route right now)
//   - capacityRejections: providers that serve the model and passed structural
//     gates but were rejected for capacity reasons (full concurrency, no free
//     memory, etc.)
//
// This is used for the pre-flight 429 check: if candidateCount == 0 &&
// capacityRejections > 0, providers exist but are all at capacity (429).
// If candidateCount == 0 && capacityRejections == 0, no provider serves
// the model at all (404/503).
//
//   - modelTooLarge: providers that serve the model but whose memory can never
//     fit it. Kept separate from capacityRejections so the caller does NOT 429
//     a model that will never fit (the client would retry forever) — it should
//     surface model_too_large / 503 instead.
func (r *Registry) QuickCapacityCheck(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int) {
	candidateCount, capacityRejections, modelTooLarge, _, _ = r.quickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, traits, false, allowedSerials...)
	return candidateCount, capacityRejections, modelTooLarge
}

func (r *Registry) QuickCapacityCheckForRequest(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, requiresVision bool, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int) {
	candidateCount, capacityRejections, modelTooLarge, _, _ = r.QuickCapacityCheckWithTTFTForRequest(model, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedSerials...)
	return candidateCount, capacityRejections, modelTooLarge
}

func (r *Registry) QuickCapacityCheckWithTTFTForRequest(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, requiresVision bool, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int, bestTTFT time.Duration, hasTTFT bool) {
	return r.quickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedSerials...)
}

func (r *Registry) quickCapacityCheck(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, requiresVision bool, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int, bestTTFT time.Duration, hasTTFT bool) {
	// Use a dummy PendingRequest with the caller's actual token estimates
	// for the admission gate (freeMemoryAdmits).
	if estimatedPromptTokens <= 0 {
		estimatedPromptTokens = 500
	}
	if requestedMaxTokens <= 0 {
		requestedMaxTokens = defaultRequestedMaxTokens
	}
	dummyPR := &PendingRequest{
		RequestID:             "capacity-check",
		Model:                 model,
		EstimatedPromptTokens: estimatedPromptTokens,
		RequestedMaxTokens:    requestedMaxTokens,
	}

	// Build allowed serial set for optional provider filtering.
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	unknownTTFTCandidate := false
	now := time.Now()
	for _, p := range r.providers {
		// Filter by allowed serials before acquiring the provider lock
		// (providerMatchesAllowedSerial takes p.mu internally).
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}

		p.mu.Lock()

		// Per-provider routing gates (same source of truth as snapshotProviderLocked
		// and the admit re-check). This pre-flight only runs for public
		// (non-self-route) requests, so selfRouteOwner is false — private-only
		// machines are excluded unconditionally.
		if !r.providerPassesRoutingGatesLocked(p, model, traits, false, now) {
			p.mu.Unlock()
			continue
		}
		if p.SystemMetrics.ThermalState == "critical" {
			p.mu.Unlock()
			continue
		}
		if requiresVision && !r.providerServesVisionModelLocked(p, model) {
			p.mu.Unlock()
			continue
		}

		// Concurrency gate.
		if !p.hasConcurrencyHeadroomForModelLocked(model) {
			p.mu.Unlock()
			capacityRejections++
			continue
		}

		// Build a snapshot for the admission gate (slot state + free memory).
		snap := routingSnapshot{
			provider:           p,
			model:              model,
			slotState:          "unknown",
			totalPending:       p.pendingCount(),
			systemMetrics:      p.SystemMetrics,
			decodeTPS:          resolvedDecodeTPS(p),
			prefillTPS:         resolvedPrefillTPS(p),
			totalMemoryGB:      float64(p.Hardware.MemoryGB),
			modelSizeGB:        r.catalogSizeGBLocked(model),
			minRAMGb:           r.catalogMinRAMGbLocked(model),
			hasBackendCapacity: p.BackendCapacity != nil,
		}
		for _, pending := range p.pendingReqs {
			if pending.Model != model {
				continue
			}
			snap.pendingForModel++
			snap.pendingMaxTokens += pendingTokenBudget(pending)
		}
		if snap.hasBackendCapacity {
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
				snap.observedDecodeTPS = slot.ObservedDecodeTPS
				snap.observedPrefillTPS = slot.ObservedPrefillTPS
				snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
				snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
				snap.queuedTokenBudget = slot.QueuedTokenBudget
				snap.maxTokensPotential = slot.MaxTokensPotential
				break
			}
		}
		snap.modelLoaded = slotStateModelLoaded(snap.slotState)
		snap.availableOnDisk = !snap.modelLoaded
		snap.fleetMedianTPS = r.tpsRegistry.Median(model, p.Hardware.ChipFamily)

		p.mu.Unlock()

		// Absolute hardware-fit gate (mirrors buildCandidateWithReason). A model
		// that can never fit this node is a permanent miss, not transient
		// capacity pressure — count it separately so the caller never 429s it.
		// Skipped for a resident ("running"/"idle") model, which has demonstrably
		// fit.
		if !slotStateModelLoaded(snap.slotState) && !modelFitsHardware(snap.minRAMGb, snap.modelSizeGB, snap.totalMemoryGB) {
			modelTooLarge++
			continue
		}

		// Slot state gate (crashed/reloading are ineligible).
		if _, eligible := slotStatePenalty(snap.slotState); !eligible {
			continue
		}

		// Free memory / token budget admission gate.
		if !freeMemoryAdmits(snap, dummyPR.EstimatedPromptTokens, dummyPR.RequestedMaxTokens) {
			capacityRejections++
			continue
		}

		candidateCount++
		if snap.hasBackendCapacity {
			ttft := estimatedTTFTFromSnapshot(snap, estimatedPromptTokens)
			if !hasTTFT || ttft < bestTTFT {
				bestTTFT = ttft
				hasTTFT = true
			}
		} else {
			unknownTTFTCandidate = true
		}
	}
	if unknownTTFTCandidate {
		return candidateCount, capacityRejections, modelTooLarge, 0, false
	}
	return candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT
}
