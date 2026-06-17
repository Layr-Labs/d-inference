package registry

import "time"

// Routing v2 — W3 cold-dispatch detection.
//
// Background: the scheduler already treats an IDLE on-disk provider as an
// eligible candidate — `slotStatePenalty("unknown")` returns eligible and
// `freeMemoryAdmits` admits a cold load when the model fits and the provider has
// no in-flight work (see scheduler.go). So when an idle, fitting cold provider
// exists, `quickCapacityCheck` already counts it as a candidate and the request
// is dispatched (cold) without any new code.
//
// The cold-dispatch win W3 actually delivers is therefore in the QUEUE: the
// proven cold-load path, `TriggerModelSwaps`, only loads a cold provider for a
// model that has QUEUED demand (registry.go). When the preflight sheds a
// capacity-rejected request with an immediate 429 instead of queueing it, that
// demand is never recorded, so no cold provider is ever warmed. Queue-before-shed
// (api side) fixes that; `ColdSpillProviders` is the conservative predicate the
// preflight uses to decide whether the rarer "no eligible provider right now"
// (503) case nonetheless has an idle on-disk provider worth queueing for.

// ColdSpillProviders reports how many connected providers could serve `model`
// via a cold load right now but do NOT currently have it warm.
//
// A provider is counted only when it (a) has the model on disk and passes every
// routing safety gate the public scheduler applies (serves-catalog, trust,
// runtime-verified, private-text, challenge freshness, dispatch-load /
// inference-error cooldowns, traits, vision, allowed-serials, non-critical
// thermal), (b) physically fits the model per the catalog, and (c) is idle
// enough to evict+load it (no in-flight requests) — the same idle eligibility
// `bestModelLoadProviderLocked` requires before sending a load_model.
//
// A positive count therefore guarantees BOTH that a subsequent
// `TriggerModelSwaps` will actually send a load_model for this model AND that
// the freshly-warmed provider will pass admission for a public request with
// these traits — so the caller can safely queue the request (cold-dispatch
// spill) instead of shedding it with a 503.
//
// Returns 0 when a warm provider already exists (that is the normal warm path,
// not a cold-spill situation).
func (r *Registry) ColdSpillProviders(model string, traits RequestTraits, requiresVision bool, allowedSerials ...string) int {
	if model == "" {
		return 0
	}

	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}

	now := time.Now()
	r.mu.RLock()
	defer r.mu.RUnlock()

	// A warm provider means this is not a cold-spill case — let the warm path
	// (or queue-for-a-freeing-slot) handle it.
	if r.hasWarmProviderLocked(model, now) {
		return 0
	}

	count := 0
	for id, p := range r.providers {
		// Allowed-serial filter takes p.mu internally, so apply it before the
		// per-provider lock (mirrors quickCapacityCheck).
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		// Skip providers already loading something — a second load_model while
		// the first is in flight oscillates single-slot machines, and
		// TriggerModelSwaps would skip it anyway.
		if r.providerHasPendingLoad(id) {
			continue
		}
		if r.coldSpillProviderEligibleLocked(p, model, traits, requiresVision, now) {
			count++
		}
	}
	return count
}

// coldSpillProviderEligibleLocked reports whether provider p is a valid cold-load
// target for `model` that, once warmed, would pass admission for a public
// request carrying `traits`. It deliberately mirrors the candidate gates in
// quickCapacityCheck (public path: selfRouteOwner=false) plus the idle
// requirement TriggerModelSwaps needs. Caller must hold r.mu (read or write);
// this acquires p.mu.
func (r *Registry) coldSpillProviderEligibleLocked(p *Provider, model string, traits RequestTraits, requiresVision bool, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Structural / trust / privacy / freshness / cooldown / trait gates.
	if !r.providerPassesRoutingGatesLocked(p, model, traits, false, now) {
		return false
	}
	if p.SystemMetrics.ThermalState == "critical" {
		return false
	}
	if requiresVision && !r.providerServesVisionModelLocked(p, model) {
		return false
	}

	// Cold only: a provider already warm for the model is not a cold-spill
	// target (and would have been a candidate, so we would not be here).
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model && slotStateModelLoaded(slot.State) {
				return false
			}
		}
	}

	// Idle enough to evict+load. Mirror TriggerModelSwaps' planner gate EXACTLY
	// (coordinator pending AND backend slot busy — warm_pool_controller.go:499);
	// otherwise a provider with an empty coordinator-pending map but a running/
	// waiting backend slot passes here, the request is enqueued, and the planner
	// then refuses to load it — so it just waits out the 120s queue timeout
	// instead of failing fast (Codex #3).
	if p.pendingCount() != 0 || warmPoolBackendSlotBusyLocked(p) {
		return false
	}

	// Absolute hardware-fit gate (catalog-authoritative; falls back to the
	// weight heuristic only when unknown). Shares modelFitsHardware with the
	// scheduler so the two cannot drift.
	if entry, ok := r.modelCatalog[model]; ok && (entry.MinRAMGB > 0 || entry.SizeGB > 0) {
		if !modelFitsHardware(entry.MinRAMGB, entry.SizeGB, float64(p.Hardware.MemoryGB)) {
			return false
		}
	}

	return true
}
