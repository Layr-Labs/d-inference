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

func (r *Registry) ApplyPrefixCacheLookupV2(
	providerID string,
	msg *protocol.PrefixCacheLookupV2Message,
) bool {
	if r == nil || msg == nil {
		return false
	}
	capability, ok := r.currentPrefixCacheV2Capability(providerID, msg.ModelID, msg.Tier)
	if !ok {
		return false
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	routeKey := append([]byte(nil), r.cacheRouteKeys.route...)
	mode := r.cacheRoutingMode
	provider := r.providers[providerID]
	r.mu.RUnlock()
	if mode != CacheRoutingOn || tracker == nil {
		return false
	}
	accepted, mismatch := tracker.applyLookupV2Result(
		providerID, provider, capability, msg, routeKey, time.Now())
	if mismatch {
		r.disablePrefixCacheV2Model(providerID, msg.ModelID, msg.Tier, provider, tracker, capability)
	}
	return accepted
}

func (r *Registry) ApplyPrefixCacheReadyV2(
	providerID string,
	msg *protocol.PrefixCacheReadyV2Message,
) bool {
	if r == nil || msg == nil {
		return false
	}
	capability, ok := r.currentPrefixCacheV2Capability(providerID, msg.ModelID, msg.Tier)
	if !ok {
		return false
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	routeKey := append([]byte(nil), r.cacheRouteKeys.route...)
	mode := r.cacheRoutingMode
	provider := r.providers[providerID]
	r.mu.RUnlock()
	if mode != CacheRoutingOn || tracker == nil {
		return false
	}
	accepted, mismatch := tracker.applyReadyV2Result(
		providerID, provider, capability, msg, routeKey, time.Now())
	if mismatch {
		r.disablePrefixCacheV2Model(providerID, msg.ModelID, msg.Tier, provider, tracker, capability)
	}
	return accepted
}

func (r *Registry) currentPrefixCacheV2Capability(
	providerID, modelID, tier string,
) (protocol.PrefixCacheV2Capability, bool) {
	r.mu.RLock()
	provider := r.providers[providerID]
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if provider == nil {
		return protocol.PrefixCacheV2Capability{}, false
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if provider.PrefixCacheProtocol < 2 {
		return protocol.PrefixCacheV2Capability{}, false
	}
	capability, ok := provider.prefixCacheCapabilityLocked(modelID, tier)
	ok = ok && capability.Enabled && capability.Ready
	if ok && tracker != nil &&
		tracker.capabilityRejected(providerID, modelID, tier, capability) {
		return protocol.PrefixCacheV2Capability{}, false
	}
	return capability, ok
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
		tracker.invalidateProviderModel(providerID, modelID, cacheHolderRemovalCapabilityChange)
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

func (t *cacheRoutingTracker) applyLookupV2Result(
	providerID string,
	provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheLookupV2Message,
	routeKey []byte,
	now time.Time,
) (bool, bool) {
	if t == nil ||
		!validCacheOutcome(msg.Outcome) ||
		!validCacheReceiptTier(msg.Tier) ||
		!validV2Stage(msg.StageMs) ||
		!validV2Anchor(msg.PromptAnchor, capability.BlockSize) {
		return false, false
	}
	if msg.Outcome == "hit" {
		if msg.Tier == "ssd" && usesExplicitCacheCheckpoints(msg.Tier, capability) &&
			(msg.RequiredRecomputeTokens != 0 || msg.StageMs <= 0) {
			return false, false
		}
		if msg.MatchedAnchor == nil ||
			!validV2Anchor(*msg.MatchedAnchor, capability.BlockSize) ||
			msg.MatchedAnchor.TokenCount > msg.PromptAnchor.TokenCount ||
			msg.RequiredRecomputeTokens < 0 ||
			msg.RequiredRecomputeTokens > msg.MatchedAnchor.TokenCount ||
			msg.ExpectedPrefillTokensSaved !=
				msg.MatchedAnchor.TokenCount-msg.RequiredRecomputeTokens {
			return false, false
		}
	} else if msg.MatchedAnchor != nil ||
		msg.RequiredRecomputeTokens != 0 ||
		msg.ExpectedPrefillTokensSaved != 0 {
		return false, false
	}

	t.mu.Lock()
	defer t.mu.Unlock()
	t.sweepIfDueLocked(now)
	attempt, ok := t.activeAttemptLocked(msg.CacheReceiptNonce, now)
	if !ok || !attempt.V2 || attempt.lookupSeen(msg.Tier) ||
		attempt.ProviderID != providerID ||
		attempt.RequestID != msg.RequestID ||
		attempt.Model != msg.ModelID ||
		attempt.capability(msg.Tier) != capability {
		return false, false
	}
	if provider != nil && attempt.Provider != provider {
		return false, false
	}
	if !v2IdentityMatches(
		msg.ModelID, msg.ModelAggregateHash, msg.PromptContractID, msg.CacheEpoch, capability,
	) {
		return false, true
	}
	if attempt.ExpectedPrompt != msg.PromptAnchor {
		return false, true
	}
	if msg.MatchedAnchor != nil &&
		attempt.ExpectedBoundaries[msg.MatchedAnchor.TokenCount] != msg.MatchedAnchor.ChainHash {
		return false, true
	}
	if !t.acceptV2SequenceLocked(providerID, capability, msg.Tier, msg.CacheSeq) {
		return false, false
	}
	if msg.Tier == "memory" {
		attempt.MemoryLookupSeen = true
	} else {
		attempt.LookupSeen = true
	}
	t.attempts[msg.CacheReceiptNonce] = attempt
	switch msg.Outcome {
	case "hit":
		anchor := *msg.MatchedAnchor
		key := cacheTierBoundaryKey(routeKey, attempt.Plan, anchor, msg.Tier)
		if key == "" {
			return false, false
		}
		holder := cacheHolder{
			ProviderID:              providerID,
			Provider:                provider,
			ModelID:                 msg.ModelID,
			ModelAggregateHash:      msg.ModelAggregateHash,
			PromptContractID:        msg.PromptContractID,
			CacheEpoch:              msg.CacheEpoch,
			Anchor:                  anchor,
			RequiredRecomputeTokens: msg.RequiredRecomputeTokens,
			StageMs:                 msg.StageMs,
			UpdatedAt:               now,
			ExpiresAt:               now.Add(t.receiptTTL(msg.Tier)),
		}
		if msg.Tier == "ssd" && msg.StageMs > 0 {
			holder.stageMeasurement = &cacheStageMeasurement{
				milliseconds: msg.StageMs, expiresAt: holder.ExpiresAt, capability: capability,
			}
		}
		t.upsertHolderLocked(key, holder)
	case "miss_absent", "miss_corrupt":
		for _, anchor := range attempt.Plan.Boundaries {
			t.removeHolderLocked(
				cacheTierBoundaryKey(routeKey, attempt.Plan, anchor, msg.Tier),
				providerID,
				cacheHolderRemovalMissInvalidation,
			)
		}
	}
	if msg.Tier == "ssd" {
		t.ssdLookups++
		switch msg.Outcome {
		case "hit":
			t.ssdHits++
		case "miss_absent", "miss_corrupt":
			t.ssdMisses++
		}
	}
	return true, false
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

func (t *cacheRoutingTracker) applyReadyV2Result(
	providerID string,
	provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheReadyV2Message,
	routeKey []byte,
	now time.Time,
) (bool, bool) {
	if t == nil ||
		msg.Outcome != "ready" ||
		!validCacheReceiptTier(msg.Tier) ||
		!validV2Stage(msg.StageMs) ||
		len(msg.ReadyAnchors) < 1 || len(msg.ReadyAnchors) > cacheReadyAnchorLimit(msg.Tier, capability) {
		return false, false
	}
	for index, anchor := range msg.ReadyAnchors {
		if !validV2Anchor(anchor, capability.BlockSize) ||
			(index > 0 && anchor.TokenCount <= msg.ReadyAnchors[index-1].TokenCount) {
			return false, false
		}
	}
	final := msg.ReadyAnchors[len(msg.ReadyAnchors)-1]
	if msg.RequiredRecomputeTokens < 0 ||
		msg.RequiredRecomputeTokens > final.TokenCount ||
		msg.ExpectedPrefillTokensSaved != final.TokenCount-msg.RequiredRecomputeTokens {
		return false, false
	}

	t.mu.Lock()
	defer t.mu.Unlock()
	t.sweepIfDueLocked(now)
	attempt, ok := t.activeAttemptLocked(msg.CacheReceiptNonce, now)
	if !ok || !attempt.V2 || !attempt.lookupSeen(msg.Tier) ||
		attempt.ProviderID != providerID ||
		attempt.RequestID != msg.RequestID ||
		attempt.Model != msg.ModelID ||
		attempt.capability(msg.Tier) != capability ||
		final.TokenCount <= attempt.lastReadyAnchor(msg.Tier).TokenCount {
		return false, false
	}
	if provider != nil && attempt.Provider != provider {
		return false, false
	}
	if !v2IdentityMatches(
		msg.ModelID, msg.ModelAggregateHash, msg.PromptContractID, msg.CacheEpoch, capability,
	) {
		return false, true
	}
	if usesExplicitCacheCheckpoints(msg.Tier, capability) {
		// Explicit checkpoints prove only endpoints in the verified input.
		// The last input block need not itself be reusable (e.g. Qwen at 4096).
		if msg.Tier == "ssd" && (msg.RequiredRecomputeTokens != 0 || msg.StageMs <= 0) {
			return false, false
		}
		for _, anchor := range msg.ReadyAnchors {
			if attempt.ExpectedBoundaries[anchor.TokenCount] != anchor.ChainHash {
				return false, true
			}
		}
	} else if msg.ReadyAnchors[0] != attempt.ExpectedPrompt {
		return false, true
	}
	if !t.acceptV2SequenceLocked(providerID, capability, msg.Tier, msg.CacheSeq) {
		return false, false
	}
	if msg.Tier == "memory" {
		attempt.MemoryLastReadyAnchor = final
	} else {
		attempt.LastReadyAnchor = final
	}
	t.attempts[msg.CacheReceiptNonce] = attempt
	for _, anchor := range msg.ReadyAnchors {
		recompute := min(msg.RequiredRecomputeTokens, anchor.TokenCount)
		key := cacheTierBoundaryKey(routeKey, attempt.Plan, anchor, msg.Tier)
		if key == "" {
			return false, false
		}
		holder := cacheHolder{
			ProviderID:              providerID,
			Provider:                provider,
			ModelID:                 msg.ModelID,
			ModelAggregateHash:      msg.ModelAggregateHash,
			PromptContractID:        msg.PromptContractID,
			CacheEpoch:              msg.CacheEpoch,
			Anchor:                  anchor,
			RequiredRecomputeTokens: recompute,
			StageMs:                 msg.StageMs,
			UpdatedAt:               now,
			ExpiresAt:               now.Add(t.receiptTTL(msg.Tier)),
		}
		if msg.Tier == "ssd" {
			t.preserveStageMeasurementLocked(key, &holder, capability, now)
		}
		t.upsertHolderLocked(key, holder)
	}
	if msg.Tier == "ssd" {
		t.ssdDonations++
	}
	return true, false
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
