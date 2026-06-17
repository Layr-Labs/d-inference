package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TriggerModelSwaps checks for queued requests that have no warm provider
// and sends load_model to cold providers that have the model available on
// disk. This enables demand-driven model swapping: when requests queue for
// a model that no provider has warm, the coordinator proactively triggers
// a swap on an idle provider.
//
// Called after heartbeat processing and queue drain to catch demand that
// can't be satisfied by warm providers alone.
func (r *Registry) TriggerModelSwaps() {
	if r.queue == nil {
		return
	}

	queuedModels := r.queue.QueuedModels()
	if len(queuedModels) == 0 {
		return
	}

	now := time.Now()
	r.expirePendingModelLoads(now)

	actions := r.planModelLoadActions(queuedModels, now)
	actions = r.reservePendingModelLoads(actions, now)
	r.sendModelLoadActions(actions)
}

func (r *Registry) expirePendingModelLoads(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for key, expiresAt := range r.pendingModelLoads {
		if now.After(expiresAt) {
			delete(r.pendingModelLoads, key)
			delete(r.pendingModelLoadStarted, key)
		}
	}
}

func (r *Registry) planModelLoadActions(queuedModels []string, now time.Time) []modelLoadAction {
	r.mu.RLock()
	defer r.mu.RUnlock()

	selectedProviders := make(map[string]struct{})
	actions := make([]modelLoadAction, 0, len(queuedModels))
	for _, model := range queuedModels {
		if r.hasWarmProviderLocked(model, now) {
			continue
		}

		providerID := r.bestModelLoadProviderLocked(model, now, selectedProviders)
		if providerID == "" {
			continue
		}
		selectedProviders[providerID] = struct{}{}
		actions = append(actions, modelLoadAction{providerID: providerID, modelID: model})
	}
	return actions
}

// hasWarmProviderLocked reports whether a connected provider already has the
// model warm. Caller must hold r.mu (read or write).
func (r *Registry) hasWarmProviderLocked(model string, now time.Time) bool {
	for _, p := range r.providers {
		p.mu.Lock()
		warm := r.providerHasWarmModelLocked(p, model, now)
		p.mu.Unlock()
		if warm {
			return true
		}
	}
	return false
}

// providerHasWarmModelLocked checks whether the provider has the model warm
// AND passes the same routing safety gates used by the scheduler. A provider
// with stale attestation or failed privacy checks should not suppress swap
// planning. Caller must hold p.mu. Caller must hold r.mu (read or write).
func (r *Registry) providerHasWarmModelLocked(p *Provider, model string, now time.Time) bool {
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	// Private-only providers serve only their owner's self-route traffic, never
	// the public fleet. They must not suppress public swap planning: otherwise a
	// private-only machine that happens to hold a queued public model warm makes
	// the planner believe the model is already served and skip load_model to an
	// eligible public node, stranding public requests until queue timeout.
	if p.PrivateOnly {
		return false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
		return false
	}
	if !p.RuntimeVerified {
		return false
	}
	if !r.providerSupportsPrivateTextLocked(p) {
		return false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model {
				// BackendCapacity is authoritative when present.
				// Only "running" and "idle" mean the model is warm.
				return slot.State == "running" || slot.State == "idle"
			}
		}
		// Model has no slot in BackendCapacity -- it's not loaded.
		return false
	}
	// Legacy provider without BackendCapacity: fall back to WarmModels.
	for _, warmModel := range p.WarmModels {
		if warmModel == model {
			return true
		}
	}
	return false
}

// bestModelLoadProviderLocked selects the eligible provider with the fewest
// pending requests. Caller must hold r.mu (read or write).
func (r *Registry) bestModelLoadProviderLocked(model string, now time.Time, selectedProviders map[string]struct{}) string {
	bestProviderID := ""
	for id, p := range r.providers {
		if _, selected := selectedProviders[id]; selected {
			continue
		}
		// Skip providers that have any pending model load -- sending a
		// second load_model while the first is in progress can cause
		// swap oscillation on single-slot providers.
		if r.providerHasPendingLoad(id) {
			continue
		}

		pendingCount, ok := r.modelLoadCandidatePendingLocked(p, model, now)
		if !ok {
			continue
		}
		// Only consider idle providers (no in-flight requests). Sending
		// load_model to a provider that is actively serving another model
		// will fail because the active slot cannot be evicted.
		if pendingCount == 0 {
			bestProviderID = id
			break
		}
	}
	return bestProviderID
}

// modelLoadCandidatePendingLocked applies the same routing safety gates used by
// the scheduler, then returns the provider's current pending request count.
// Caller must hold r.mu (read or write).
func (r *Registry) modelLoadCandidatePendingLocked(p *Provider, model string, now time.Time) (int, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return 0, false
	}
	// Private-only providers never serve public traffic, so never pick one as a
	// public load_model target (mirrors the public-routing exclusion).
	if p.PrivateOnly {
		return 0, false
	}
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
		return 0, false
	}
	if !p.RuntimeVerified {
		return 0, false
	}
	if !r.providerSupportsPrivateTextLocked(p) {
		return 0, false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return 0, false
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return 0, false
	}

	// Memory gate: reject providers that cannot run the model per the catalog's
	// authoritative min_ram_gb (falling back to the weight heuristic only when
	// unknown). Shares modelFitsHardware with the consumer-routing admission
	// gate so the two can never drift. This prevents the coordinator from
	// sending load_model commands to machines that clearly cannot fit it, while
	// trusting the operator-published requirement rather than a synthetic
	// multiple that would exclude catalog-qualified nodes.
	if entry, ok := r.modelCatalog[model]; ok && (entry.MinRAMGB > 0 || entry.SizeGB > 0) {
		if !modelFitsHardware(entry.MinRAMGB, entry.SizeGB, float64(p.Hardware.MemoryGB)) {
			return 0, false
		}
	}

	return p.pendingCount(), true
}

func (r *Registry) reservePendingModelLoads(actions []modelLoadAction, now time.Time) []modelLoadAction {
	if len(actions) == 0 {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.pendingModelLoads == nil {
		r.pendingModelLoads = make(map[string]time.Time)
	}
	if r.pendingModelLoadStarted == nil {
		r.pendingModelLoadStarted = make(map[string]time.Time)
	}

	reserved := actions[:0]
	for _, action := range actions {
		// Check per-provider (not just per-key) to prevent concurrent
		// heartbeat goroutines from reserving the same idle provider
		// for different models.
		if r.providerHasPendingLoad(action.providerID) {
			continue
		}
		key := modelLoadKey(action.providerID, action.modelID)
		r.pendingModelLoads[key] = now.Add(pendingModelLoadTTL)
		r.pendingModelLoadStarted[key] = now
		reserved = append(reserved, action)
	}
	return reserved
}

func (r *Registry) sendModelLoadActions(actions []modelLoadAction) {
	for _, action := range actions {
		if err := r.SendLoadModel(action.providerID, action.modelID); err != nil {
			r.logger.Warn("failed to trigger model swap",
				"provider_id", action.providerID,
				"model_id", action.modelID,
				"error", err,
			)
			r.ClearPendingModelLoad(action.providerID, action.modelID)
		}
	}
}

func modelLoadKey(providerID, modelID string) string {
	return providerID + ":" + modelID
}

// providerHasPendingLoad reports whether the provider has any pending
// load_model command. Caller must hold r.mu (read or write).
func (r *Registry) providerHasPendingLoad(providerID string) bool {
	prefix := providerID + ":"
	for key := range r.pendingModelLoads {
		if len(key) > len(prefix) && key[:len(prefix)] == prefix {
			return true
		}
	}
	return false
}

// MarkModelWarm adds a model to the provider's WarmModels list if not already
// present. Called when load_model_status:succeeded arrives before the next
// heartbeat, so the scheduler sees the provider as warm during queue drain.
func (r *Registry) MarkModelWarm(providerID, modelID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	for _, wm := range p.WarmModels {
		if wm == modelID {
			return // already warm
		}
	}
	p.WarmModels = append(p.WarmModels, modelID)
	p.CurrentModel = modelID

	// Inject a synthetic "idle" slot into BackendCapacity so the scheduler
	// sees the model as warm. Without this, the scheduler only checks
	// BackendCapacity.Slots (not WarmModels) for Swift providers, and a
	// stale snapshot without the new model's slot would treat it as cold
	// until the next heartbeat arrives.
	//
	// We only add/update the new model's slot and leave existing slots
	// untouched — the provider may have multiple model slots loaded
	// simultaneously (maxModelSlots defaults to 3). The next heartbeat
	// will provide the authoritative slot list.
	if p.BackendCapacity != nil {
		found := false
		for i, slot := range p.BackendCapacity.Slots {
			if slot.Model == modelID {
				p.BackendCapacity.Slots[i].State = "idle"
				found = true
				break
			}
		}
		if !found {
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
				Model: modelID,
				State: "idle",
			})
		}
	}
}

// ClearPendingModelLoad removes a pending model load entry after a terminal
// load_model_status response and returns its observed duration.
func (r *Registry) ClearPendingModelLoad(providerID, modelID string) time.Duration {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := modelLoadKey(providerID, modelID)
	started := r.pendingModelLoadStarted[key]
	delete(r.pendingModelLoads, key)
	delete(r.pendingModelLoadStarted, key)
	if started.IsZero() {
		return 0
	}
	return time.Since(started)
}

func (r *Registry) PendingModelLoadDuration(providerID, modelID string) time.Duration {
	r.mu.RLock()
	defer r.mu.RUnlock()
	started := r.pendingModelLoadStarted[modelLoadKey(providerID, modelID)]
	if started.IsZero() {
		return 0
	}
	return time.Since(started)
}

func (r *Registry) clearPendingModelLoadsForProviderLocked(providerID string) {
	prefix := providerID + ":"
	for key := range r.pendingModelLoads {
		if len(key) > len(prefix) && key[:len(prefix)] == prefix {
			delete(r.pendingModelLoads, key)
			delete(r.pendingModelLoadStarted, key)
		}
	}
	for key := range r.pendingModelLoadStarted {
		if len(key) > len(prefix) && key[:len(prefix)] == prefix {
			delete(r.pendingModelLoadStarted, key)
		}
	}
}

// BackoffPendingModelLoadForDrain re-stamps a pending load entry with the
// short drain backoff. Called when a provider rejects load_model because it
// is draining ahead of an auto-update restart: clearing the entry outright
// would re-send load_model to the same draining provider on the very next
// TriggerModelSwaps pass, while the full failure cooldown would suppress the
// provider long after a failed restart resumed serving. A successful restart
// clears the entry anyway via Disconnect.
func (r *Registry) BackoffPendingModelLoadForDrain(providerID, modelID string) {
	r.mu.Lock()
	r.pendingModelLoads[modelLoadKey(providerID, modelID)] = time.Now().Add(pendingModelLoadDrainBackoff)
	r.mu.Unlock()
}

// RejectUnservableQueuedRequests checks whether any eligible provider can
// serve the given model. If not, all queued requests for the model are
// rejected immediately rather than waiting for the 120s queue timeout.
// Called after a load_model failure to give consumers a fast error.
func (r *Registry) RejectUnservableQueuedRequests(modelID string) {
	if r.queue == nil {
		return
	}
	if r.queue.QueueSize(modelID) == 0 {
		return
	}

	// Check if any provider can still serve this model. Only reject when
	// NO provider serves the model at all. If providers exist but are
	// temporarily at capacity (capacityRejections > 0), the requests
	// should wait — those providers may finish current work and become
	// available.
	// modelTooLarge is intentionally ignored here: a model that can never fit
	// any provider should NOT keep its queued requests waiting (they'd time out
	// after 120s) — fall through to fail them fast.
	// Base-shape check: "can any provider serve this model at all?" carries no
	// tool/vision constraint, so use the default (base) traits.
	candidates, capacityRejections, _ := r.QuickCapacityCheck(modelID, 500, defaultRequestedMaxTokens, RequestTraits{})
	if candidates > 0 || capacityRejections > 0 {
		return
	}

	// Prefer waiters are preserved only when their owner actually has an owned
	// provider serving this model (it may free up). A prefer waiter with no
	// owned provider is just waiting on the (now-unservable) public fleet, so it
	// should fail fast like any public request. Compute eligibility here —
	// OUTSIDE the queue lock — since OwnedProviderSummary takes the registry lock.
	preferOwnerEligible := make(map[string]bool)
	for _, owner := range r.queue.PreferWaiterOwners(modelID) {
		_, servesModel := r.OwnedProviderSummary(owner, modelID)
		preferOwnerEligible[owner] = servesModel > 0
	}

	failed := r.queue.FailQueuedRequestsForModel(modelID, preferOwnerEligible)
	if failed > 0 {
		r.logger.Warn("rejected queued requests for unservable model",
			"model_id", modelID,
			"rejected", failed,
		)
	}
}

func cumulativeDelta(previous, current int64) int64 {
	if current <= 0 {
		return 0
	}
	if current >= previous {
		return current - previous
	}
	// The provider process restarted and reset its in-memory counters.
	return current
}
