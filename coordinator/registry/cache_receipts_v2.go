package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
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
	if !open || !plan.Present() || !plan.HasOrigin() {
		return nil
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	current := r.cacheRoutingMode == CacheRoutingOn && tracker != nil &&
		plan.Authenticates(tracker.generation) && r.providers[provider.ID] == provider
	r.mu.RUnlock()
	if !current {
		return nil
	}

	provider.mu.Lock()
	capability, capable := provider.PrefixCacheV2Models[pr.Model]
	memoryCapability, memoryCapable := provider.PrefixCacheMemoryModels[pr.Model]
	providerID := provider.ID
	protocolVersion := provider.PrefixCacheProtocol
	revision := provider.prefixCacheRevision.Capture()
	provider.mu.Unlock()
	promptAnchor := plan.Boundaries[len(plan.Boundaries)-1]
	capable = capable && CapabilityMatchesPlan(capability, plan)
	memoryCapable = memoryCapable && CapabilityMatchesPlan(memoryCapability, plan)
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
	boundaries, valid := cacheplan.NewClaims(plan.Boundaries, blockSize, promptAnchor)
	if !valid {
		return nil
	}

	nonce, err := r.newCacheReceiptNonce()
	if err != nil {
		return err
	}
	now := tracker.now()
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
	boundaryMode := ""
	if capable {
		boundaryMode = capability.ReadyBoundaryMode
	}
	owner := newCacheAttemptOwner(tracker, plan.Provenance(), nonce, plan.CacheScope, boundaryMode, max(0, plan.RepeatedPrefixTokens))
	tracker.mu.Lock()
	tracker.storeAttemptLocked(nonce, attempt)
	if tracker.attempts.Len() > tracker.settings.MaxAttempts {
		tracker.enforceAttemptCapLocked()
	}
	tracker.mu.Unlock()

	publication := CachePublication{registry: r, request: pr, provider: provider, revision: revision, ticket: ticket, owner: owner, tracker: tracker}
	var published bool
	if r.cacheDependencies.Publications != nil {
		published = r.cacheDependencies.Publications(publication).Publish()
	} else {
		published = publication.Publish()
	}
	if published {
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
		providerID, provider, capability, msg, routeKey, tracker.now())
	decision.ResolveMismatch(CacheQuarantine{registry: r, providerID: providerID, modelID: msg.ModelID, tier: msg.Tier,
		provider: provider, tracker: tracker, expected: capability, routeKey: routeKey})
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
		providerID, provider, capability, msg, routeKey, tracker.now())
	decision.ResolveMismatch(CacheQuarantine{registry: r, providerID: providerID, modelID: msg.ModelID, tier: msg.Tier,
		provider: provider, tracker: tracker, expected: capability, routeKey: routeKey})
	return decision
}

func (r *Registry) currentPrefixCacheV2CapabilityResult(
	providerID, modelID, tier string,
) (protocol.PrefixCacheV2Capability, CacheReceiptReason) {
	admission := CacheReceiptAdmission{registry: r}
	if r.cacheDependencies.ReceiptAdmissions != nil {
		return r.cacheDependencies.ReceiptAdmissions(admission).Admit(providerID, modelID, tier)
	}
	return admission.Admit(providerID, modelID, tier)
}

func validV2Anchor(anchor protocol.PrefixCacheAnchor, blockSize uint32) bool {
	return cachepolicy.Anchor(anchor, blockSize)
}
