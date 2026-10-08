package cachetracker

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (t *Tracker[P]) ApplyReadyV2(
	providerID string,
	provider P,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheReadyV2Message,
	routeKey []byte,
	now time.Time,
	final protocol.PrefixCacheAnchor,
) CacheReceiptResult {
	t.SweepIfDueLocked(now)
	attempt, ok := t.ActiveAttemptLocked(msg.CacheReceiptNonce, now)
	if !ok {
		return RejectCacheReceipt(CacheReceiptAttemptUnavailable)
	}
	if !attempt.V2 || attempt.ProviderID != providerID || attempt.RequestID != msg.RequestID || attempt.Model != msg.ModelID {
		return RejectCacheReceipt(CacheReceiptAttemptBinding)
	}
	if !attempt.SeenLookup(msg.Tier) {
		return RejectCacheReceipt(CacheReceiptLookupNotSeen)
	}
	if attempt.Capability(msg.Tier) != capability {
		return RejectCacheReceipt(CacheReceiptCapabilityChanged)
	}
	if final.TokenCount <= attempt.ReadyAnchor(msg.Tier).TokenCount {
		return RejectCacheReceipt(CacheReceiptNonAdvancingReady)
	}
	if provider != t.zero && attempt.Provider != provider {
		return RejectCacheReceipt(CacheReceiptConnectionChanged)
	}
	if !cachepolicy.IdentityMatches(
		msg.ModelID, msg.ModelAggregateHash, msg.PromptContractID, msg.CacheEpoch, capability,
	) {
		return MismatchCacheReceipt(CacheReceiptIdentityMismatch)
	}
	if cachepolicy.ExplicitCheckpoints(msg.Tier, capability) {
		// Explicit checkpoints prove only endpoints in the verified input.
		// The last input block need not itself be reusable (e.g. Qwen at 4096).
		if msg.Tier == "ssd" && (msg.RequiredRecomputeTokens != 0 || msg.StageMs <= 0) {
			return RejectCacheReceipt(CacheReceiptInvalid)
		}
		for _, anchor := range msg.ReadyAnchors {
			if !attempt.ExpectedBoundaries.Matches(anchor) {
				return MismatchCacheReceiptForPlan(CacheReceiptReadyMismatch, attempt.Plan)
			}
		}
	} else if msg.ReadyAnchors[0] != attempt.ExpectedPrompt {
		return MismatchCacheReceiptForPlan(CacheReceiptReadyMismatch, attempt.Plan)
	}
	if !t.AcceptV2SequenceLocked(providerID, capability, msg.Tier, msg.CacheSeq) {
		return RejectCacheReceipt(CacheReceiptSequence)
	}
	final.ChainHash = strings.Clone(final.ChainHash)
	t.proofs.ResetStrikes(providerID, msg.ModelID, msg.Tier, capability, now)
	if msg.Tier == "memory" {
		attempt.MemoryLastReadyAnchor = final
	} else {
		attempt.LastReadyAnchor = final
	}
	t.attempts.Store(strings.Clone(msg.CacheReceiptNonce), attempt)
	for _, anchor := range msg.ReadyAnchors {
		recompute := min(msg.RequiredRecomputeTokens, anchor.TokenCount)
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
			RequiredRecomputeTokens: recompute,
			StageMs:                 msg.StageMs,
			UpdatedAt:               now,
			ExpiresAt:               now.Add(t.ReceiptTTL(msg.Tier)),
		}
		if msg.Tier == "ssd" {
			t.PreserveStageMeasurementLocked(key, &holder, capability, now)
		}
		t.UpsertHolderLocked(key, holder)
	}
	if msg.Tier == "ssd" {
		t.ssdDonations++
	}
	return CacheReceiptResult{Accepted: true, Reason: CacheReceiptAccepted}
}
