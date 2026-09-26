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
	defer func() {
		p.mu.Unlock()
		r.mu.Unlock()
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
		// Like registration, inventory may include off-catalog local models
		// regardless of ownership or PrivateOnly. A configured catalog still
		// excludes them from public routing; hashes and capabilities fail closed.
		entry := r.modelCatalog[model.ID]
		if !r.providerMeetsModelRequirementsLocked(p, model.ID) ||
			(entry.WeightHash != "" && !strings.EqualFold(model.WeightHash, entry.WeightHash)) {
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
		}
	}
	p.Models = append([]protocol.ModelInfo(nil), msg.Models...)
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
	return added, removed, p.drainGeneration, nil
}

// ResumeProviderModels opens admission only after a committed replacement receipt
// reached the wire. A late write cannot resume a newer drain or another session.
func (r *Registry) ResumeProviderModels(p *Provider, generation uint64) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if p == nil || r.providers[p.ID] != p || generation == 0 {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.drainCommitted || !p.drainReplacementPending || p.drainGeneration != generation {
		return false
	}
	p.drainCommitted = false
	p.drainReplacementPending = false
	p.drainRequestID = ""
	p.drainingUntil = time.Time{}
	return true
}
