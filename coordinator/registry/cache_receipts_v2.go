package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/cacheattempt"
)

// PreparePrefixCacheV2Attempt requests provider proof for an exact sidecar
// plan. Unsupported or mismatched providers remain ordinary cold candidates.
func (r *Registry) PreparePrefixCacheV2Attempt(
	pr *PendingRequest,
	provider *Provider,
	plan CachePlan,
) error {
	if r == nil || pr == nil || provider == nil {
		return nil
	}
	ticket, open := pr.beginCachePreparation()
	if !open || !plan.present() || plan.generation == nil {
		return nil
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	current := r.cacheRoutingMode == CacheRoutingOn && tracker != nil &&
		plan.generation == tracker.generation && r.providers[provider.ID] == provider
	r.mu.RUnlock()
	if !current {
		return nil
	}

	provider.mu.Lock()
	capability, capable := provider.PrefixCacheV2Models[pr.Model]
	memoryCapability, memoryCapable := provider.PrefixCacheMemoryModels[pr.Model]
	providerID := provider.ID
	protocolVersion := provider.PrefixCacheProtocol
	revision := provider.prefixCacheRevision
	provider.mu.Unlock()
	promptAnchor := plan.Boundaries[len(plan.Boundaries)-1]
	capable = capable && capabilityMatchesPlan(capability, plan)
	memoryCapable = memoryCapable && capabilityMatchesPlan(memoryCapability, plan)
	if !capable {
		capability = protocol.PrefixCacheV2Capability{}
	}
	if !memoryCapable {
		memoryCapability = protocol.PrefixCacheV2Capability{}
	}
	blockSize := capability.BlockSize
	if memoryCapable {
		blockSize = memoryCapability.BlockSize
	}
	if protocolVersion < 2 || (!capable && !memoryCapable) ||
		!validV2Anchor(promptAnchor, blockSize) {
		return nil
	}
	boundaries := make(map[int]string, len(plan.Boundaries))
	for _, boundary := range plan.Boundaries {
		if !validV2Anchor(boundary, blockSize) ||
			boundary.TokenCount > promptAnchor.TokenCount {
			return nil
		}
		if _, duplicate := boundaries[boundary.TokenCount]; duplicate {
			return nil
		}
		boundaries[boundary.TokenCount] = boundary.ChainHash
	}

	nonce, err := newCacheReceiptNonce()
	if err != nil {
		return err
	}
	now := time.Now()
	attempt := cacheAttempt{
		RequestID:          pr.RequestID,
		ProviderID:         providerID,
		Provider:           provider,
		Model:              pr.Model,
		CreatedAt:          now,
		ExpiresAt:          now.Add(cacheRoutingInFlightAttemptTTL),
		V2:                 true,
		Plan:               directoryPlan(plan),
		V2Capability:       capability,
		MemoryCapability:   memoryCapability,
		ExpectedPrompt:     promptAnchor,
		ExpectedBoundaries: boundaries,
	}
	metadata := cacheattempt.Metadata{Nonce: nonce, Scope: plan.CacheScope}
	if capable {
		metadata.BoundaryMode = capability.ReadyBoundaryMode
	}
	owner := cacheattempt.New(plan.generation, tracker.directory, metadata)
	tracker.directory.RegisterAttempt(nonce, attempt)

	if r.publishCacheAttempt(pr, provider, revision, ticket, tracker, owner) {
		ttftCalibration.discardPrediction(pr.RequestID, pr.Attempt)
	}
	return nil
}

func (r *Registry) ApplyPrefixCacheLookupV2(providerID string, msg *protocol.PrefixCacheLookupV2Message) bool {
	return r.ApplyPrefixCacheLookupV2Result(providerID, msg).Accepted
}

func (r *Registry) ApplyPrefixCacheLookupV2Result(
	providerID string,
	msg *protocol.PrefixCacheLookupV2Message,
) CacheReceiptResult {
	if r == nil || msg == nil {
		return rejectCacheReceipt(CacheReceiptInvalid)
	}
	capability, reason := r.currentPrefixCacheV2CapabilityResult(providerID, msg.ModelID, msg.Tier)
	if reason != CacheReceiptAccepted {
		return rejectCacheReceipt(reason)
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	routeKey := append([]byte(nil), r.cacheRouteKeys.route...)
	mode := r.cacheRoutingMode
	provider := r.providers[providerID]
	r.mu.RUnlock()
	if mode != CacheRoutingOn || tracker == nil {
		return rejectCacheReceipt(CacheReceiptInactive)
	}
	decision := tracker.directory.ApplyLookup(
		providerID, provider, capability, msg, routeKey, time.Now())
	if decision.ProofMismatch() {
		r.disablePrefixCacheV2Model(providerID, msg.ModelID, msg.Tier, provider, tracker, capability)
	}
	return decision
}

func (r *Registry) ApplyPrefixCacheReadyV2(providerID string, msg *protocol.PrefixCacheReadyV2Message) bool {
	return r.ApplyPrefixCacheReadyV2Result(providerID, msg).Accepted
}

func (r *Registry) ApplyPrefixCacheReadyV2Result(
	providerID string,
	msg *protocol.PrefixCacheReadyV2Message,
) CacheReceiptResult {
	if r == nil || msg == nil {
		return rejectCacheReceipt(CacheReceiptInvalid)
	}
	capability, reason := r.currentPrefixCacheV2CapabilityResult(providerID, msg.ModelID, msg.Tier)
	if reason != CacheReceiptAccepted {
		return rejectCacheReceipt(reason)
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	routeKey := append([]byte(nil), r.cacheRouteKeys.route...)
	mode := r.cacheRoutingMode
	provider := r.providers[providerID]
	r.mu.RUnlock()
	if mode != CacheRoutingOn || tracker == nil {
		return rejectCacheReceipt(CacheReceiptInactive)
	}
	decision := tracker.directory.ApplyReady(
		providerID, provider, capability, msg, routeKey, time.Now())
	if decision.ProofMismatch() {
		r.disablePrefixCacheV2Model(providerID, msg.ModelID, msg.Tier, provider, tracker, capability)
	}
	return decision
}

func (r *Registry) currentPrefixCacheV2Capability(providerID, modelID, tier string) (protocol.PrefixCacheV2Capability, bool) {
	c, reason := r.currentPrefixCacheV2CapabilityResult(providerID, modelID, tier)
	return c, reason == CacheReceiptAccepted
}

func (r *Registry) currentPrefixCacheV2CapabilityResult(
	providerID, modelID, tier string,
) (protocol.PrefixCacheV2Capability, CacheReceiptReason) {
	r.mu.RLock()
	provider := r.providers[providerID]
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if provider == nil {
		return protocol.PrefixCacheV2Capability{}, CacheReceiptProviderMissing
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if provider.PrefixCacheProtocol < 2 {
		return protocol.PrefixCacheV2Capability{}, CacheReceiptProtocol
	}
	capability, ok := provider.prefixCacheCapabilityLocked(modelID, tier)
	if !ok || !capability.Enabled || !capability.Ready {
		return protocol.PrefixCacheV2Capability{}, CacheReceiptCapabilityUnavailable
	}
	if tracker != nil &&
		tracker.directory.CapabilityRejected(providerID, modelID, tier, capability) {
		return protocol.PrefixCacheV2Capability{}, CacheReceiptCapabilityFenced
	}
	return capability, CacheReceiptAccepted
}

func (r *Registry) disablePrefixCacheV2Model(
	providerID, modelID, tier string,
	provider *Provider, tracker *cacheRoutingTracker,
	expected protocol.PrefixCacheV2Capability,
) {
	// One r → provider → tracker transition also fences connection replacement.
	// These leaf mutations perform no I/O or callbacks into the registry.
	r.mu.RLock()
	defer r.mu.RUnlock()
	current := r.providers[providerID] == provider && r.cacheRouting == tracker
	if !current || provider == nil || tracker == nil {
		return
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	capability, ok := provider.prefixCacheCapabilityLocked(modelID, tier)
	if ok && capability == expected && tracker.directory.RejectCapability(providerID, modelID, tier, capability) {
		tracker.directory.InvalidateProviderModel(providerID, modelID, cacheHolderRemovalProofMismatch)
		provider.prefixCacheRevision++
	}
}
