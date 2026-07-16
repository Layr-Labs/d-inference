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
	r.ForgetCacheAttempt(pr)

	provider.mu.Lock()
	capability, capable := provider.PrefixCacheV2Models[pr.Model]
	providerID := provider.ID
	protocolVersion := provider.PrefixCacheProtocol
	provider.mu.Unlock()
	if !plan.present() {
		return nil
	}
	promptAnchor := plan.Boundaries[len(plan.Boundaries)-1]
	if protocolVersion < 2 || !capable ||
		!capability.Enabled || !capability.Ready ||
		plan.ModelAggregateHash != capability.ModelAggregateHash ||
		plan.PromptContractID != capability.PromptContractID ||
		plan.CacheScope == "" ||
		!validV2Anchor(promptAnchor, capability.BlockSize) {
		return nil
	}
	boundaries := make(map[int]string, len(plan.Boundaries))
	for _, boundary := range plan.Boundaries {
		if !validV2Anchor(boundary, capability.BlockSize) ||
			boundary.TokenCount > promptAnchor.TokenCount {
			return nil
		}
		if _, duplicate := boundaries[boundary.TokenCount]; duplicate {
			return nil
		}
		boundaries[boundary.TokenCount] = boundary.ChainHash
	}
	if boundaries[promptAnchor.TokenCount] != promptAnchor.ChainHash {
		return nil
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
		ExpectedPrompt:     promptAnchor,
		ExpectedBoundaries: boundaries,
	}
	r.cacheRouting.mu.Lock()
	r.cacheRouting.storeAttemptLocked(nonce, attempt)
	if len(r.cacheRouting.attempts) > r.cacheRouting.maxAttempts {
		r.cacheRouting.enforceAttemptCapLocked()
	}
	r.cacheRouting.mu.Unlock()

	pr.CacheReceiptNonce = nonce
	pr.CacheScope = plan.CacheScope
	pr.PrefixCacheProtocol = 2
	pr.setCacheRoutingParticipates(true)
	ttftCalibration.discardPrediction(pr.RequestID, pr.Attempt)
	return nil
}

func (r *Registry) ApplyPrefixCacheLookupV2(
	providerID string,
	msg *protocol.PrefixCacheLookupV2Message,
) bool {
	if r == nil || msg == nil {
		return false
	}
	capability, ok := r.currentPrefixCacheV2Capability(providerID, msg.ModelID)
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
		r.disablePrefixCacheV2Model(providerID, msg.ModelID)
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
	capability, ok := r.currentPrefixCacheV2Capability(providerID, msg.ModelID)
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
		r.disablePrefixCacheV2Model(providerID, msg.ModelID)
	}
	return accepted
}

func (r *Registry) currentPrefixCacheV2Capability(
	providerID, modelID string,
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
	capability, ok := provider.PrefixCacheV2Models[modelID]
	ok = ok && capability.Enabled && capability.Ready
	if ok && tracker != nil &&
		tracker.capabilityRejected(providerID, modelID, capability) {
		return protocol.PrefixCacheV2Capability{}, false
	}
	return capability, ok
}

func (r *Registry) disablePrefixCacheV2Model(providerID, modelID string) {
	r.mu.RLock()
	provider := r.providers[providerID]
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if provider == nil {
		return
	}
	provider.mu.Lock()
	capability, ok := provider.PrefixCacheV2Models[modelID]
	provider.mu.Unlock()
	if tracker != nil && ok {
		tracker.rejectCapability(providerID, modelID, capability)
		tracker.invalidateProviderModel(providerID, modelID)
	}
}

func (t *cacheRoutingTracker) capabilityRejected(
	providerID, modelID string,
	capability protocol.PrefixCacheV2Capability,
) bool {
	key := cacheV2ProviderModelKey{ProviderID: providerID, ModelID: modelID}
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
	providerID, modelID string,
	capability protocol.PrefixCacheV2Capability,
) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.rejectedV2[cacheV2ProviderModelKey{
		ProviderID: providerID,
		ModelID:    modelID,
	}] = capability
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
		msg.Tier != "ssd" ||
		!validV2Stage(msg.StageMs) ||
		!validV2Anchor(msg.PromptAnchor, capability.BlockSize) {
		return false, false
	}
	if msg.Outcome == "hit" {
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
	if !ok || !attempt.V2 || attempt.LookupSeen ||
		attempt.ProviderID != providerID ||
		attempt.RequestID != msg.RequestID ||
		attempt.Model != msg.ModelID ||
		attempt.V2Capability != capability {
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
	if !t.acceptV2SequenceLocked(providerID, capability, msg.CacheSeq) {
		return false, false
	}
	attempt.LookupSeen = true
	t.attempts[msg.CacheReceiptNonce] = attempt
	switch msg.Outcome {
	case "hit":
		anchor := *msg.MatchedAnchor
		key := cacheBoundaryKey(routeKey, attempt.Plan, capability.CacheEpoch, anchor)
		if key == "" {
			return false, false
		}
		t.upsertHolderLocked(key, cacheHolder{
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
			ExpiresAt:               now.Add(t.ttl),
		})
	case "miss_absent", "miss_corrupt":
		for _, anchor := range attempt.Plan.Boundaries {
			t.removeHolderLocked(
				cacheBoundaryKey(routeKey, attempt.Plan, capability.CacheEpoch, anchor),
				providerID,
			)
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
		msg.Tier != "ssd" ||
		!validV2Stage(msg.StageMs) ||
		len(msg.ReadyAnchors) < 1 || len(msg.ReadyAnchors) > 2 {
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
	if !ok || !attempt.V2 || !attempt.LookupSeen ||
		attempt.ProviderID != providerID ||
		attempt.RequestID != msg.RequestID ||
		attempt.Model != msg.ModelID ||
		attempt.V2Capability != capability ||
		final.TokenCount <= attempt.LastReadyAnchor.TokenCount {
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
	if msg.ReadyAnchors[0] != attempt.ExpectedPrompt {
		return false, true
	}
	if !t.acceptV2SequenceLocked(providerID, capability, msg.CacheSeq) {
		return false, false
	}
	attempt.LastReadyAnchor = final
	t.attempts[msg.CacheReceiptNonce] = attempt
	for _, anchor := range msg.ReadyAnchors {
		recompute := min(msg.RequiredRecomputeTokens, anchor.TokenCount)
		key := cacheBoundaryKey(routeKey, attempt.Plan, capability.CacheEpoch, anchor)
		if key == "" {
			return false, false
		}
		t.upsertHolderLocked(key, cacheHolder{
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
			ExpiresAt:               now.Add(t.ttl),
		})
	}
	return true, false
}

func (t *cacheRoutingTracker) acceptV2SequenceLocked(
	providerID string,
	capability protocol.PrefixCacheV2Capability,
	sequence uint64,
) bool {
	if sequence == 0 {
		return false
	}
	key := cacheV2SequenceKey{
		ProviderID: providerID,
		ModelID:    capability.ModelID,
		CacheEpoch: capability.CacheEpoch,
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
