package cachepolicy

import "github.com/eigeninference/d-inference/coordinator/protocol"

// ValidLookupV2 validates the receipt shape before the controller takes its lock.
func ValidLookupV2(capability protocol.PrefixCacheV2Capability, msg *protocol.PrefixCacheLookupV2Message) bool {
	if msg == nil || !Outcome(msg.Outcome) || !Tier(msg.Tier) ||
		!Stage(msg.StageMs) || !Anchor(msg.PromptAnchor, capability.BlockSize) {
		return false
	}
	if msg.Outcome == "hit" {
		if msg.Tier == "ssd" && ExplicitCheckpoints(msg.Tier, capability) &&
			(msg.RequiredRecomputeTokens != 0 || msg.StageMs <= 0) {
			return false
		}
		if msg.MatchedAnchor == nil ||
			!Anchor(*msg.MatchedAnchor, capability.BlockSize) ||
			msg.MatchedAnchor.TokenCount > msg.PromptAnchor.TokenCount ||
			msg.RequiredRecomputeTokens < 0 ||
			msg.RequiredRecomputeTokens > msg.MatchedAnchor.TokenCount ||
			msg.ExpectedPrefillTokensSaved != msg.MatchedAnchor.TokenCount-msg.RequiredRecomputeTokens {
			return false
		}
	} else if msg.MatchedAnchor != nil || msg.RequiredRecomputeTokens != 0 || msg.ExpectedPrefillTokensSaved != 0 {
		return false
	}
	return true
}

// ValidReadyV2 validates anchors before any receipt evidence is mutated.
func ValidReadyV2(capability protocol.PrefixCacheV2Capability, msg *protocol.PrefixCacheReadyV2Message) bool {
	if msg == nil || msg.Outcome != "ready" || !Tier(msg.Tier) || !Stage(msg.StageMs) ||
		len(msg.ReadyAnchors) < 1 || len(msg.ReadyAnchors) > ReadyAnchorLimit(msg.Tier, capability) {
		return false
	}
	for index, anchor := range msg.ReadyAnchors {
		if !Anchor(anchor, capability.BlockSize) ||
			(index > 0 && anchor.TokenCount <= msg.ReadyAnchors[index-1].TokenCount) {
			return false
		}
	}
	final := msg.ReadyAnchors[len(msg.ReadyAnchors)-1]
	if msg.RequiredRecomputeTokens < 0 || msg.RequiredRecomputeTokens > final.TokenCount ||
		msg.ExpectedPrefillTokensSaved != final.TokenCount-msg.RequiredRecomputeTokens {
		return false
	}
	return true
}
