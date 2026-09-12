package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (t *cacheRoutingTracker) applyReadyV2Result(
	providerID string,
	provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheReadyV2Message,
	routeKey []byte,
	now time.Time,
) (bool, bool) {
	result := t.applyReadyV2Decision(providerID, provider, capability, msg, routeKey, now)
	return result.Accepted, result.mismatch
}

func (t *cacheRoutingTracker) applyReadyV2Decision(
	providerID string,
	provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheReadyV2Message,
	routeKey []byte,
	now time.Time,
) CacheReceiptResult {
	if t == nil || msg == nil ||
		msg.Outcome != "ready" ||
		!validCacheReceiptTier(msg.Tier) ||
		!validV2Stage(msg.StageMs) ||
		len(msg.ReadyAnchors) < 1 || len(msg.ReadyAnchors) > cacheReadyAnchorLimit(msg.Tier, capability) {
		return rejectCacheReceipt(CacheReceiptInvalid)
	}
	for index, anchor := range msg.ReadyAnchors {
		if !validV2Anchor(anchor, capability.BlockSize) ||
			(index > 0 && anchor.TokenCount <= msg.ReadyAnchors[index-1].TokenCount) {
			return rejectCacheReceipt(CacheReceiptInvalid)
		}
	}
	final := msg.ReadyAnchors[len(msg.ReadyAnchors)-1]
	if msg.RequiredRecomputeTokens < 0 ||
		msg.RequiredRecomputeTokens > final.TokenCount ||
		msg.ExpectedPrefillTokensSaved != final.TokenCount-msg.RequiredRecomputeTokens {
		return rejectCacheReceipt(CacheReceiptInvalid)
	}

	t.mu.Lock()
	defer t.mu.Unlock()
	t.sweepIfDueLocked(now)
	attempt, ok := t.activeAttemptLocked(msg.CacheReceiptNonce, now)
	if !ok {
		return rejectCacheReceipt(CacheReceiptAttemptUnavailable)
	}
	if !attempt.V2 || attempt.ProviderID != providerID || attempt.RequestID != msg.RequestID || attempt.Model != msg.ModelID {
		return rejectCacheReceipt(CacheReceiptAttemptBinding)
	}
	if !attempt.lookupSeen(msg.Tier) {
		return rejectCacheReceipt(CacheReceiptLookupNotSeen)
	}
	if attempt.capability(msg.Tier) != capability {
		return rejectCacheReceipt(CacheReceiptCapabilityChanged)
	}
	if final.TokenCount <= attempt.lastReadyAnchor(msg.Tier).TokenCount {
		return rejectCacheReceipt(CacheReceiptNonAdvancingReady)
	}
	if provider != nil && attempt.Provider != provider {
		return rejectCacheReceipt(CacheReceiptConnectionChanged)
	}
	if !v2IdentityMatches(
		msg.ModelID, msg.ModelAggregateHash, msg.PromptContractID, msg.CacheEpoch, capability,
	) {
		return mismatchCacheReceipt(CacheReceiptIdentityMismatch)
	}
	if usesExplicitCacheCheckpoints(msg.Tier, capability) {
		// Explicit checkpoints prove only endpoints in the verified input.
		// The last input block need not itself be reusable (e.g. Qwen at 4096).
		if msg.Tier == "ssd" && (msg.RequiredRecomputeTokens != 0 || msg.StageMs <= 0) {
			return rejectCacheReceipt(CacheReceiptInvalid)
		}
		for _, anchor := range msg.ReadyAnchors {
			if attempt.ExpectedBoundaries[anchor.TokenCount] != anchor.ChainHash {
				return mismatchCacheReceipt(CacheReceiptReadyMismatch)
			}
		}
	} else if msg.ReadyAnchors[0] != attempt.ExpectedPrompt {
		return mismatchCacheReceipt(CacheReceiptReadyMismatch)
	}
	if !t.acceptV2SequenceLocked(providerID, capability, msg.Tier, msg.CacheSeq) {
		return rejectCacheReceipt(CacheReceiptSequence)
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
			return rejectCacheReceipt(CacheReceiptRouteKey)
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
	return CacheReceiptResult{Accepted: true, Reason: CacheReceiptAccepted}
}
