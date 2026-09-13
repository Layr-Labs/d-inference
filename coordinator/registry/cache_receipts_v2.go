package registry

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
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
		Plan:               plan,
		V2Capability:       capability,
		MemoryCapability:   memoryCapability,
		ExpectedPrompt:     promptAnchor,
		ExpectedBoundaries: boundaries,
	}
	owner := &cacheAttemptOwner{tracker: tracker, generation: plan.generation,
		nonce: nonce, scope: plan.CacheScope}
	if capable {
		owner.boundaryMode = capability.ReadyBoundaryMode
	}
	tracker.mu.Lock()
	tracker.storeAttemptLocked(nonce, attempt)
	if len(tracker.attempts) > tracker.maxAttempts {
		tracker.enforceAttemptCapLocked()
	}
	tracker.mu.Unlock()

	if r.publishCacheAttempt(pr, provider, revision, ticket, owner) {
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
	decision := tracker.applyLookupV2Decision(
		providerID, provider, capability, msg, routeKey, time.Now())
	if decision.mismatch {
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
	decision := tracker.applyReadyV2Decision(
		providerID, provider, capability, msg, routeKey, time.Now())
	if decision.mismatch {
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
		tracker.capabilityRejected(providerID, modelID, tier, capability) {
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
	if ok && capability == expected && tracker.rejectCapability(providerID, modelID, tier, capability) {
		tracker.invalidateProviderModel(providerID, modelID, cacheHolderRemovalProofMismatch)
		provider.prefixCacheRevision++
	}
}

func (t *cacheRoutingTracker) capabilityRejected(
	providerID, modelID, tier string,
	capability protocol.PrefixCacheV2Capability,
) bool {
	key := cacheV2ProviderModelKey{ProviderID: providerID, ModelID: modelID, Tier: tier}
	t.mu.Lock()
	defer t.mu.Unlock()
	rejected, ok := t.rejectedV2[key]
	if ok && rejected != capability {
		delete(t.rejectedV2, key)
		return false
	}
	return ok
}

func (t *cacheRoutingTracker) rejectCapability(
	providerID, modelID, tier string,
	capability protocol.PrefixCacheV2Capability,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.generation.revoked.Load() {
		return false
	}
	t.rejectedV2[cacheV2ProviderModelKey{
		ProviderID: providerID,
		ModelID:    modelID,
		Tier:       tier,
	}] = capability
	return true
}

func (t *cacheRoutingTracker) applyLookupV2(
	providerID string,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheLookupV2Message,
	now time.Time,
) bool {
	accepted, _ := t.applyLookupV2Result(
		providerID, nil, capability, msg, []byte("test-cache-route-key"), now)
	return accepted
}

func (t *cacheRoutingTracker) applyReadyV2(
	providerID string,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheReadyV2Message,
	now time.Time,
) bool {
	accepted, _ := t.applyReadyV2Result(
		providerID, nil, capability, msg, []byte("test-cache-route-key"), now)
	return accepted
}

func (t *cacheRoutingTracker) acceptV2SequenceLocked(
	providerID string,
	capability protocol.PrefixCacheV2Capability,
	tier string,
	sequence uint64,
) bool {
	if sequence == 0 || t.generation.revoked.Load() {
		return false
	}
	key := cacheV2SequenceKey{
		ProviderID: providerID,
		ModelID:    capability.ModelID,
		CacheEpoch: capability.CacheEpoch,
		Tier:       tier,
	}
	if sequence <= t.v2Sequences[key] {
		return false
	}
	t.v2Sequences[key] = sequence
	return true
}

func v2IdentityMatches(
	modelID, aggregateHash, contractID, epoch string,
	capability protocol.PrefixCacheV2Capability,
) bool {
	return modelID == capability.ModelID &&
		aggregateHash == capability.ModelAggregateHash &&
		contractID == capability.PromptContractID &&
		epoch == capability.CacheEpoch &&
		capability.Enabled &&
		capability.Ready
}

func validV2Anchor(anchor protocol.PrefixCacheAnchor, blockSize uint32) bool {
	return blockSize > 0 &&
		anchor.TokenCount > 0 &&
		anchor.TokenCount <= cacheRoutingMaxReceiptTokens &&
		anchor.TokenCount%int(blockSize) == 0 &&
		validLowerHex256(anchor.ChainHash)
}

func validV2Stage(stage float64) bool {
	return stage >= 0 &&
		stage <= cacheRoutingMaxStageMs &&
		!math.IsNaN(stage) &&
		!math.IsInf(stage, 0)
}
