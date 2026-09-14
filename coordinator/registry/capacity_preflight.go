package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

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
	candidateCount, capacityRejections, modelTooLarge, _, _ = r.quickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedSerials...)
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
	// Per-model index: visit only providers advertising the model (gates
	// unchanged; see model_index.go).
	for _, p := range r.providersForModelLocked(model) {
		// Filter by allowed serials before acquiring the provider lock
		// (providerMatchesAllowedSerial takes p.mu internally).
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}

		p.mu.Lock()

		// Per-provider routing gates (same source of truth as snapshotProviderIntoLockedEx
		// and the admit re-check). This pre-flight only runs for public
		// (non-self-route) requests, so selfRouteOwner is false — private-only
		// machines are excluded unconditionally.
		//
		// ignoreProviderBreaker=true: the per-provider node-health
		// breaker is a SELECTION-time gate that fails open in the dispatch path
		// (selectBestCandidateScanLocked / ReserveProviderEx). The preflight must
		// fail open on it too — otherwise an all-breaker-open fleet reports 0
		// candidates AND 0 capacity-rejections here, and the consumer hard-503s
		// "no_provider" BEFORE dispatch's fail-open valve can serve a probe,
		// re-introducing the very model-wide outage the valve exists to prevent.
		// Every other gate (incl. the shape-keyed inference-error cooldown) is
		// still honored; the breaker still steers SELECTION away from bad nodes.
		if !r.providerPassesRoutingGatesLockedEx(p, model, traits, false, now, true, false) {
			// A pair blocked ONLY by the capacity-reject cooldown is TRANSIENT
			// capacity, not structural absence: the box exists, serves the model,
			// and will be re-probed when its TTL lapses. Count it as a
			// capacityRejection so an all-cooled model surfaces to the consumer
			// as capacity (429 + Retry-After / queue-before-shed) instead of a
			// "no providers" 503 — the cooldown must read as "busy fleet", never
			// as "the model vanished". The ignoreCapacityCooldown re-check keeps
			// a pair that ALSO fails a structural gate (offline, untrusted,
			// render-broken, …) out of the count. Structural filters applied
			// AFTER the gates on the main path must apply here too:
			// thermal-critical and vision-blind pairs are excluded outright
			// (same as the main path just below), and a pair whose model can
			// never fit the hardware counts as modelTooLarge — never as
			// transient capacity, or a fleet of undersized cooled boxes would
			// read as "busy, retry" for a model that will never fit.
			if (r.gateOf(p).CapacityCooled(model, now) || providerDrainingLocked(p, now)) &&
				r.providerPassesRoutingGatesLockedEx(p, model, traits, false, now, true, true) &&
				p.SystemMetrics.ThermalState != "critical" &&
				(!requiresVision || r.providerServesVisionModelLocked(p, model, false)) {
				// Mirror the absolute hardware-fit gate (skipped for a
				// resident model, which has demonstrably fit).
				slotState := "unknown"
				totalMemGB := float64(p.Hardware.MemoryGB)
				if p.BackendCapacity != nil {
					if p.BackendCapacity.TotalMemoryGB > 0 {
						totalMemGB = p.BackendCapacity.TotalMemoryGB
					}
					for _, slot := range p.BackendCapacity.Slots {
						if slot.Model == model {
							slotState = slot.State
							break
						}
					}
				}
				if !routingcost.SlotStateModelLoaded(slotState) &&
					!modelFitsHardware(r.catalogMinRAMGbLocked(model), r.catalogSizeGBLocked(model), totalMemGB) {
					modelTooLarge++
				} else {
					capacityRejections++
				}
			}
			p.mu.Unlock()
			continue
		}
		if p.SystemMetrics.ThermalState == "critical" {
			p.mu.Unlock()
			continue
		}
		if requiresVision && !r.providerServesVisionModelLocked(p, model, false) {
			p.mu.Unlock()
			continue
		}

		// Concurrency gate (with the quality-concurrency cap, same as the dispatch
		// snapshot — resolves the model's own static solo rate internally so
		// routing and the shed preflight stay consistent and a slow model's
		// quality cap counts a saturated box as a capacity rejection here too).
		if !r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model) {
			p.mu.Unlock()
			capacityRejections++
			continue
		}

		// Project the same locked provider state used by reservation scoring.
		var snap routingSnapshot
		r.fillRoutingSnapshotPLocked(&snap, p, model, now)

		p.mu.Unlock()

		// Absolute hardware-fit gate (mirrors buildCandidateWithReason). A model
		// that can never fit this node is a permanent miss, not transient
		// capacity pressure — count it separately so the caller never 429s it.
		// Skipped for a resident ("running"/"idle") model, which has demonstrably
		// fit.
		if !routingcost.SlotStateModelLoaded(snap.SlotState) && !modelFitsHardware(snap.MinRAMGB, snap.ModelSizeGB, snap.TotalMemoryGB) {
			modelTooLarge++
			continue
		}

		// Slot state gate (crashed/reloading are ineligible).
		if _, eligible := routingcost.SlotStatePenalty(snap.SlotState); !eligible {
			continue
		}

		// Free memory / token budget admission gate.
		if !freeMemoryAdmits(&snap, dummyPR.EstimatedPromptTokens, dummyPR.RequestedMaxTokens) {
			capacityRejections++
			continue
		}

		candidateCount++
		if snap.HasBackendCapacity {
			ttft := routingPolicy.EstimatedTTFT(&snap, estimatedPromptTokens)
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
