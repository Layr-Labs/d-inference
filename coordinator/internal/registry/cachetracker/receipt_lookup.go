package cachetracker

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (t *Tracker[P]) ApplyLookupV2(
	providerID string,
	provider P,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheLookupV2Message,
	routeKey []byte,
	now time.Time,
) CacheReceiptResult {
	t.SweepIfDueLocked(now)
	attempt, ok := t.ActiveAttemptLocked(msg.CacheReceiptNonce, now)
	if !ok {
		return RejectCacheReceipt(CacheReceiptAttemptUnavailable)
	}
	if !attempt.V2 || attempt.ProviderID != providerID || attempt.RequestID != msg.RequestID || attempt.Model != msg.ModelID {
		return RejectCacheReceipt(CacheReceiptAttemptBinding)
	}
	if attempt.SeenLookup(msg.Tier) {
		return RejectCacheReceipt(CacheReceiptDuplicateLookup)
	}
	if attempt.Capability(msg.Tier) != capability {
		return RejectCacheReceipt(CacheReceiptCapabilityChanged)
	}
	if provider != t.zero && attempt.Provider != provider {
		return RejectCacheReceipt(CacheReceiptConnectionChanged)
	}
	if !cachepolicy.IdentityMatches(
		msg.ModelID, msg.ModelAggregateHash, msg.PromptContractID, msg.CacheEpoch, capability,
	) {
		return MismatchCacheReceipt(CacheReceiptIdentityMismatch)
	}
	if attempt.ExpectedPrompt != msg.PromptAnchor {
		result := MismatchCacheReceiptForPlan(CacheReceiptPromptMismatch, attempt.Plan)
		result.PromptMismatch = CachePromptHashMismatch
		if msg.PromptAnchor.TokenCount < attempt.ExpectedPrompt.TokenCount {
			result.PromptMismatch = CachePromptShorter
		} else if msg.PromptAnchor.TokenCount > attempt.ExpectedPrompt.TokenCount {
			result.PromptMismatch = CachePromptLonger
		}
		return result
	}
	if msg.MatchedAnchor != nil &&
		!attempt.ExpectedBoundaries.Matches(*msg.MatchedAnchor) {
		return MismatchCacheReceiptForPlan(CacheReceiptMatchedMismatch, attempt.Plan)
	}
	if !t.AcceptV2SequenceLocked(providerID, capability, msg.Tier, msg.CacheSeq) {
		return RejectCacheReceipt(CacheReceiptSequence)
	}
	t.proofs.ResetStrikes(providerID, msg.ModelID, msg.Tier, capability, now)
	if msg.Tier == "memory" {
		attempt.MemoryLookupSeen = true
	} else {
		attempt.LookupSeen = true
	}
	t.attempts.Store(strings.Clone(msg.CacheReceiptNonce), attempt)
	switch msg.Outcome {
	case "hit":
		anchor := *msg.MatchedAnchor
		key := CacheTierBoundaryKey(routeKey, attempt.Plan, anchor, msg.Tier)
		if key == "" {
			return RejectCacheReceipt(CacheReceiptRouteKey)
		}
		holder := Holder[P]{
			ProviderID:              providerID,
			Provider:                provider,
			ModelID:                 msg.ModelID,
			ModelAggregateHash:      msg.ModelAggregateHash,
			PromptContractID:        msg.PromptContractID,
			CacheEpoch:              msg.CacheEpoch,
			BlockHashVersion:        capability.BlockHashVersion,
			ReadyBoundaryMode:       capability.ReadyBoundaryMode,
			Tier:                    msg.Tier,
			Anchor:                  anchor,
			RequiredRecomputeTokens: msg.RequiredRecomputeTokens,
			StageMs:                 msg.StageMs,
			UpdatedAt:               now,
			ExpiresAt:               now.Add(t.ReceiptTTL(msg.Tier)),
		}
		if msg.Tier == "ssd" && msg.StageMs > 0 {
			holder.Measurement = NewMeasurement(msg.StageMs, holder.ExpiresAt, capability)

		}
		t.UpsertHolderLocked(key, holder)
		t.SupersedeDeeperHoldersLocked(providerID, attempt.Plan, anchor, msg.Tier, msg.CacheEpoch, routeKey)
	case "miss_absent", "miss_corrupt":
		for _, anchor := range attempt.Plan.Boundaries {
			t.InvalidateBoundaryLocked(
				CacheTierBoundaryKey(routeKey, attempt.Plan, anchor, msg.Tier),
				providerID, msg.Tier, msg.CacheEpoch,
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
