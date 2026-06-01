package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// SendLoadModel instructs a provider to eagerly load a model so it becomes
// warm for incoming requests. The provider will autonomously evict idle
// models to make room. This is a fire-and-forget call — the coordinator
// does not block waiting for the load to complete. The provider replies
// asynchronously with a load_model_status message.
func (r *Registry) SendLoadModel(providerID, modelID string) error {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return fmt.Errorf("provider %q not found", providerID)
	}

	msg := protocol.LoadModelMessage{
		Type:    protocol.TypeLoadModel,
		ModelID: modelID,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal load_model message: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	p.mu.Lock()
	conn := p.Conn
	p.mu.Unlock()

	if conn == nil {
		return fmt.Errorf("provider %q has no active connection", providerID)
	}

	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		return fmt.Errorf("failed to send load_model to provider %q: %w", providerID, err)
	}

	r.logger.Info("sent load_model to provider",
		"provider_id", providerID,
		"model_id", modelID,
	)
	return nil
}

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
	for key, sentAt := range r.pendingModelLoads {
		if now.Sub(sentAt) > pendingModelLoadTTL {
			delete(r.pendingModelLoads, key)
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
	if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
		return 0, false
	}
	if !p.RuntimeVerified {
		return 0, false
	}
	if !providerSupportsPrivateTextLocked(p) {
		return 0, false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return 0, false
	}
	if !r.providerServesCatalogModelLocked(p, model) {
		return 0, false
	}

	// Memory gate: reject providers that cannot physically load the model.
	// The provider applies a 2x multiplier on model weight size when deciding
	// whether to load (ensureModelLoaded uses estimatedMemoryGb * 2.0 for
	// headroom). Use the catalog SizeGB * 2.5 as the coordinator-side gate
	// (slightly less conservative since the provider will reject anyway if
	// it truly doesn't fit). This prevents the coordinator from sending
	// load_model commands to machines that will always OOM-reject them.
	if entry, ok := r.modelCatalog[model]; ok && entry.SizeGB > 0 {
		requiredGB := entry.SizeGB * 2.5
		providerMemGB := float64(p.Hardware.MemoryGB)
		if providerMemGB > 0 && requiredGB > providerMemGB {
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

	reserved := actions[:0]
	for _, action := range actions {
		// Check per-provider (not just per-key) to prevent concurrent
		// heartbeat goroutines from reserving the same idle provider
		// for different models.
		if r.providerHasPendingLoad(action.providerID) {
			continue
		}
		r.pendingModelLoads[modelLoadKey(action.providerID, action.modelID)] = now
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
// load_model_status response.
func (r *Registry) ClearPendingModelLoad(providerID, modelID string) {
	r.mu.Lock()
	delete(r.pendingModelLoads, modelLoadKey(providerID, modelID))
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
	candidates, capacityRejections := r.QuickCapacityCheck(modelID, 500, defaultRequestedMaxTokens)
	if candidates > 0 || capacityRejections > 0 {
		return
	}

	failed := r.queue.FailQueuedRequestsForModel(modelID)
	if failed > 0 {
		r.logger.Warn("rejected queued requests for unservable model",
			"model_id", modelID,
			"rejected", failed,
		)
	}
}
