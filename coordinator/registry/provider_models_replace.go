package registry

import (
	"errors"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// ReplaceProviderModels validates or commits inventory on the exact live session
// that completed the named drain. Routing stays fenced through commit; the caller
// must successfully write the receipt before ResumeProviderModels with the returned
// generation. Validation-only and rejection leave inventory and drain unchanged.
func (r *Registry) ReplaceProviderModels(p *Provider, msg *protocol.ModelsReplaceMessage) (added, removed []string, generation uint64, err error) {
	r.mu.Lock()
	if p == nil || r.providers[p.ID] != p {
		r.mu.Unlock()
		return nil, nil, 0, errors.New("disconnected")
	}
	p.mu.Lock()
	releasedModelLoad := false
	defer func() {
		p.mu.Unlock()
		r.mu.Unlock()
		if releasedModelLoad {
			r.RequestWarmPoolTrigger()
		}
	}()
	if msg.RequestID == "" || len(msg.RequestID) > 64 || msg.DrainRequestID == "" ||
		!p.drainCommitted || !p.drainReady || p.drainRequestID != msg.DrainRequestID {
		return nil, nil, 0, errors.New("invalid_drain")
	}
	if len(msg.Models) == 0 || len(p.pendingReqs) != 0 || msg.ToolConstraintProtocol < 0 || msg.ToolConstraintProtocol > ToolConstraintProtocolV1 {
		return nil, nil, 0, errors.New("invalid_models")
	}
	selected := make(map[string]protocol.ModelInfo, len(msg.Models))
	for _, model := range msg.Models {
		if model.ID == "" {
			return nil, nil, 0, errors.New("invalid_models")
		}
		if _, duplicate := selected[model.ID]; duplicate {
			return nil, nil, 0, errors.New("invalid_models")
		}
		// Match registration: off-catalog local models remain eligible for
		// owner routing, while public routing still requires catalog membership.
		entry := r.modelCatalog[model.ID]
		if !r.providerMeetsModelRequirementsLocked(p, model.ID) ||
			(entry.WeightHash != "" && !entry.acceptsWeightHash(model.WeightHash)) {
			return nil, nil, 0, errors.New("invalid_models")
		}
		selected[model.ID] = model
	}
	tools := make(map[string]struct{}, len(msg.ToolConstraintModels))
	for _, id := range msg.ToolConstraintModels {
		if _, exists := selected[id]; !exists || msg.ToolConstraintProtocol != ToolConstraintProtocolV1 {
			return nil, nil, 0, errors.New("invalid_models")
		}
		if _, duplicate := tools[id]; duplicate {
			return nil, nil, 0, errors.New("invalid_models")
		}
		tools[id] = struct{}{}
	}
	if msg.ValidateOnly {
		return nil, nil, 0, nil
	}

	// Retained slots survive only with the same weight identity. Cache evidence
	// is invalidated before reopening routing; its tracker is a leaf lock.
	invalidated := make(map[string]cacheHolderRemovalReason)
	oldIDs := make(map[string]struct{}, len(p.Models))
	for _, old := range p.Models {
		oldIDs[old.ID] = struct{}{}
		next, retained := selected[old.ID]
		if !retained {
			removed = append(removed, old.ID)
			if p.Status != StatusUntrusted {
				r.modelProviderDec(old.ID)
			}
		}
		if !retained || !strings.EqualFold(old.WeightHash, next.WeightHash) {
			invalidated[old.ID] = cacheHolderRemovalCapabilityChange
			delete(p.PrefixCacheStatuses, old.ID)
			delete(p.PrefixCacheV2Models, old.ID)
			delete(p.PrefixCacheMemoryModels, old.ID)
			delete(p.kvBackends, old.ID)
			delete(p.TemplateHashes, old.ID)
		}
	}
	r.cacheRouting.invalidateProviderModels(p.ID, invalidated)
	keepRuntime := func(id string) bool {
		_, exists := selected[id]
		_, stale := invalidated[id]
		return exists && !stale
	}
	warm := p.WarmModels[:0]
	for _, id := range p.WarmModels {
		if keepRuntime(id) {
			warm = append(warm, id)
		}
	}
	p.WarmModels = warm
	if !keepRuntime(p.CurrentModel) {
		p.CurrentModel = ""
	}
	if p.BackendCapacity != nil {
		capacity := *p.BackendCapacity
		capacity.Slots = make([]protocol.BackendSlotCapacity, 0, len(capacity.Slots))
		for _, slot := range p.BackendCapacity.Slots {
			if keepRuntime(slot.Model) {
				capacity.Slots = append(capacity.Slots, slot)
			}
		}
		p.BackendCapacity = &capacity
	}
	for key := range r.pendingModelLoads {
		if key.ProviderID == p.ID && !keepRuntime(key.ModelID) {
			delete(r.pendingModelLoads, key)
			delete(r.pendingModelLoadStarted, key)
			releasedModelLoad = true
		}
	}
	p.Models = append([]protocol.ModelInfo(nil), msg.Models...)
	// The owner load equation must never join a new weight estimate to the
	// previous inventory's memory sample, even when the model ID is retained.
	// Routing remains fenced until a fresh capacity heartbeat; that heartbeat
	// restores both owner fields alongside the accepted capacity snapshot.
	p.CapacityModelIDs = nil
	p.CapacityAcceptedAt = time.Time{}
	p.firstContentMeasurements = nil
	p.warmWorkCounters = nil
	p.ToolConstraintProtocol = msg.ToolConstraintProtocol
	p.ToolConstraintModels = tools
	if len(invalidated) > 0 {
		p.prefixCacheRevision++
	}
	p.PrefixCacheStatuses, p.PrefixCacheStatusReported = reconcilePrefixCacheStatuses(
		p.PrefixCacheProtocol, p.PrefixCacheV2Models, p.PrefixCacheStatuses, p.PrefixCacheStatusReported)
	for _, model := range p.Models {
		added = append(added, model.ID)
		if _, existed := oldIDs[model.ID]; !existed && p.Status != StatusUntrusted {
			r.modelProviderInc(model.ID)
		}
	}
	p.syncModelIndexLocked()
	p.drainReady = false
	p.drainReplacementPending = true
	p.drainReplacementAcked = false
	p.drainReplacementReadySeq = 0
	p.drainReplacementAppliedSeq = 0
	p.drainReplacementID = msg.RequestID
	// A failed receipt can be reconciled on this session after another drain.
	// Retain removals from every unconfirmed replacement, except IDs restored
	// by the final selection. Otherwise their queued requests wait for timeout.
	pendingRemoved := make([]string, 0, len(p.drainRemovedModels)+len(removed))
	seenRemoved := make(map[string]struct{}, len(p.drainRemovedModels)+len(removed))
	for _, id := range append(append([]string(nil), p.drainRemovedModels...), removed...) {
		if _, restored := selected[id]; restored {
			continue
		}
		if _, seen := seenRemoved[id]; !seen {
			seenRemoved[id] = struct{}{}
			pendingRemoved = append(pendingRemoved, id)
		}
	}
	p.drainRemovedModels = pendingRemoved
	return added, removed, p.drainGeneration, nil
}

// ConfirmProviderModelsReceipt records a successful control-writer handoff. The
// provider still owns closed admission until it sends models_replace_ready.
func (r *Registry) ConfirmProviderModelsReceipt(p *Provider, requestID string, generation uint64) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if p == nil || r.providers[p.ID] != p || generation == 0 {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.drainCommitted || !p.drainReplacementPending || p.drainGeneration != generation || p.drainReplacementID != requestID {
		return false
	}
	p.drainReplacementAcked = true
	return true
}

// ResumeProviderModels records matching local readiness. Routing opens only
// after an accepted serving heartbeat has replaced the pre-switch capacity.
// A stale readiness frame cannot resume a newer drain or another session.
func (r *Registry) ResumeProviderModels(p *Provider, requestID, drainRequestID string, capacitySeq uint64) (added, removed []string, resumed bool, ack *protocol.ModelsReplaceResumedMessage) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if p == nil || r.providers[p.ID] != p {
		return nil, nil, false, nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	// A control-writer failure after routing resumed must not turn a retry of
	// the identical ready frame into a permanently unacknowledged switch.
	if requestID != "" && drainRequestID != "" && capacitySeq > 0 && !p.drainCommitted &&
		p.lastResumedModelReplacement.RequestID == requestID &&
		p.lastResumedModelReplacement.DrainRequestID == drainRequestID &&
		p.lastResumedModelReplacement.CapacitySeq == capacitySeq {
		last := p.lastResumedModelReplacement
		return nil, nil, false, &last
	}
	if !p.drainCommitted || !p.drainReplacementPending || !p.drainReplacementAcked ||
		p.drainReplacementID != requestID || p.drainRequestID != drainRequestID || capacitySeq == 0 {
		return nil, nil, false, nil
	}
	if capacitySeq > p.drainReplacementReadySeq {
		p.drainReplacementReadySeq = capacitySeq
	}
	return p.resumeProviderModelsIfReadyLocked()
}

// ResumeProviderModelsAfterHeartbeat completes a replacement whose readiness
// arrived before its refreshed capacity heartbeat. Heartbeat marked freshness
// under p.mu only after applying an ordered, serving capacity snapshot.
func (r *Registry) ResumeProviderModelsAfterHeartbeat(p *Provider) (added, removed []string, resumed bool, ack *protocol.ModelsReplaceResumedMessage) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if p == nil || r.providers[p.ID] != p {
		return nil, nil, false, nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.resumeProviderModelsIfReadyLocked()
}

// Caller holds p.mu and the registry read lock.
func (p *Provider) resumeProviderModelsIfReadyLocked() (added, removed []string, resumed bool, ack *protocol.ModelsReplaceResumedMessage) {
	if !p.drainCommitted || !p.drainReplacementPending || !p.drainReplacementAcked ||
		p.drainReplacementReadySeq == 0 || p.drainReplacementAppliedSeq < p.drainReplacementReadySeq {
		return nil, nil, false, nil
	}
	confirmation := protocol.ModelsReplaceResumedMessage{
		Type: protocol.TypeModelsReplaceResumed, RequestID: p.drainReplacementID,
		DrainRequestID: p.drainRequestID, CapacitySeq: p.drainReplacementReadySeq,
	}
	for _, model := range p.Models {
		added = append(added, model.ID)
	}
	removed = append([]string(nil), p.drainRemovedModels...)
	p.drainCommitted = false
	p.drainReplacementPending = false
	p.drainReplacementAcked = false
	p.drainReplacementReadySeq = 0
	p.drainReplacementAppliedSeq = 0
	p.drainReplacementID = ""
	p.drainRemovedModels = nil
	p.drainRequestID = ""
	p.drainingUntil = time.Time{}
	p.lastResumedModelReplacement = confirmation
	return added, removed, true, &confirmation
}
