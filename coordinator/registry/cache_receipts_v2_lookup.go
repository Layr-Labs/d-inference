package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (t *cacheRoutingTracker) applyLookupV2Result(
	providerID string,
	provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheLookupV2Message,
	routeKey []byte,
	now time.Time,
) (bool, bool) {
	result := t.applyLookupV2Decision(providerID, provider, capability, msg, routeKey, now)
	return result.Accepted, result.mismatch
}

func (t *cacheRoutingTracker) applyLookupV2Decision(
	providerID string,
	provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheLookupV2Message,
	routeKey []byte,
	now time.Time,
) CacheReceiptResult {
	if t == nil || msg == nil ||
		!validCacheOutcome(msg.Outcome) ||
		!validCacheReceiptTier(msg.Tier) ||
		!validV2Stage(msg.StageMs) ||
		!validV2Anchor(msg.PromptAnchor, capability.BlockSize) {
		return rejectCacheReceipt(CacheReceiptInvalid)
	}
	if msg.Outcome == "hit" {
		if msg.Tier == "ssd" && usesExplicitCacheCheckpoints(msg.Tier, capability) &&
			(msg.RequiredRecomputeTokens != 0 || msg.StageMs <= 0) {
			return rejectCacheReceipt(CacheReceiptInvalid)
		}
		if msg.MatchedAnchor == nil ||
			!validV2Anchor(*msg.MatchedAnchor, capability.BlockSize) ||
			msg.MatchedAnchor.TokenCount > msg.PromptAnchor.TokenCount ||
			msg.RequiredRecomputeTokens < 0 ||
			msg.RequiredRecomputeTokens > msg.MatchedAnchor.TokenCount ||
			msg.ExpectedPrefillTokensSaved !=
				msg.MatchedAnchor.TokenCount-msg.RequiredRecomputeTokens {
			return rejectCacheReceipt(CacheReceiptInvalid)
		}
	} else if msg.MatchedAnchor != nil ||
		msg.RequiredRecomputeTokens != 0 ||
		msg.ExpectedPrefillTokensSaved != 0 {
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
	if attempt.lookupSeen(msg.Tier) {
		return rejectCacheReceipt(CacheReceiptDuplicateLookup)
	}
	if attempt.capability(msg.Tier) != capability {
		return rejectCacheReceipt(CacheReceiptCapabilityChanged)
	}
	if provider != nil && attempt.Provider != provider {
		return rejectCacheReceipt(CacheReceiptConnectionChanged)
	}
	if !v2IdentityMatches(
		msg.ModelID, msg.ModelAggregateHash, msg.PromptContractID, msg.CacheEpoch, capability,
	) {
		return mismatchCacheReceipt(CacheReceiptIdentityMismatch)
	}
	if attempt.ExpectedPrompt != msg.PromptAnchor {
		result := mismatchCacheReceipt(CacheReceiptPromptMismatch)
		result.PromptMismatch = CachePromptHashMismatch
		if msg.PromptAnchor.TokenCount < attempt.ExpectedPrompt.TokenCount {
			result.PromptMismatch = CachePromptShorter
		} else if msg.PromptAnchor.TokenCount > attempt.ExpectedPrompt.TokenCount {
			result.PromptMismatch = CachePromptLonger
		}
		return result
	}
	if msg.MatchedAnchor != nil &&
		attempt.ExpectedBoundaries[msg.MatchedAnchor.TokenCount] != msg.MatchedAnchor.ChainHash {
		return mismatchCacheReceipt(CacheReceiptMatchedMismatch)
	}
	if !t.acceptV2SequenceLocked(providerID, capability, msg.Tier, msg.CacheSeq) {
		return rejectCacheReceipt(CacheReceiptSequence)
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
	return CacheReceiptResult{Accepted: true, Reason: CacheReceiptAccepted, PromptTokens: attempt.Plan.PromptTokenCount}
}
