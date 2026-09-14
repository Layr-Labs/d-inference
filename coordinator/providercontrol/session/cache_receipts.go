package session

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (s *Session) cacheLookup(lookupMsg *protocol.PrefixCacheLookupMessage) {
	if s.deps.Registry().ApplyPrefixCacheLookup(s.providerID, lookupMsg) {
		s.deps.Telemetry.Incr("routing.cache_lookup_receipt", []string{"outcome:" + lookupMsg.Outcome, "tier:" + s.deps.Telemetry.Cache.Tier(lookupMsg.Tier)})
		s.deps.Telemetry.Cache.SSDLookup("v1", lookupMsg.Outcome, lookupMsg.StageMs)
	} else {
		s.deps.Telemetry.Incr("routing.cache_receipt_rejected", []string{"type:lookup"})
	}
}

func (s *Session) cacheReady(readyMsg *protocol.PrefixCacheReadyMessage) {
	if s.deps.Registry().ApplyPrefixCacheReady(s.providerID, readyMsg) {
		s.deps.Telemetry.Incr("routing.cache_ready_receipt", []string{"tier:" + s.deps.Telemetry.Cache.Tier(readyMsg.Tier)})
		s.deps.Telemetry.Cache.SSDDonation("v1", readyMsg.StageMs, readyMsg.ReadyTokens)
	} else {
		s.deps.Telemetry.Incr("routing.cache_receipt_rejected", []string{"type:ready"})
	}
}

func (s *Session) cacheLookupV2(lookupMsg *protocol.PrefixCacheLookupV2Message) {
	receipt := s.deps.Registry().ApplyPrefixCacheLookupV2Result(s.providerID, lookupMsg)
	s.deps.Telemetry.Cache.Receipt("lookup_v2", receipt)
	s.deps.Telemetry.Cache.ModelReceipt(lookupMsg.ModelID, lookupMsg.Tier, "lookup_v2", receipt)
	if receipt.Accepted {
		s.deps.Telemetry.Cache.ModelLookup(lookupMsg, receipt)
		s.deps.Telemetry.Incr("routing.cache_lookup_receipt", []string{
			"protocol:v2",
			"outcome:" + lookupMsg.Outcome,
			"tier:" + s.deps.Telemetry.Cache.Tier(lookupMsg.Tier),
		})
		if lookupMsg.Tier == "ssd" {
			s.deps.Telemetry.Cache.SSDLookup("v2", lookupMsg.Outcome, lookupMsg.StageMs)
		}
	} else {
		s.deps.Telemetry.Incr("routing.cache_receipt_rejected", []string{"type:lookup_v2", "reason:" + string(receipt.Reason)})
	}
}

func (s *Session) cacheReadyV2(readyMsg *protocol.PrefixCacheReadyV2Message) {
	receipt := s.deps.Registry().ApplyPrefixCacheReadyV2Result(s.providerID, readyMsg)
	s.deps.Telemetry.Cache.Receipt("ready_v2", receipt)
	s.deps.Telemetry.Cache.ModelReceipt(readyMsg.ModelID, readyMsg.Tier, "ready_v2", receipt)
	if receipt.Accepted {
		s.deps.Telemetry.Cache.ModelDonation(readyMsg, receipt)
		s.deps.Telemetry.Incr("routing.cache_ready_receipt", []string{
			"protocol:v2",
			"tier:" + s.deps.Telemetry.Cache.Tier(readyMsg.Tier),
		})
		if readyMsg.Tier == "ssd" {
			donatedTokens := 0
			if len(readyMsg.ReadyAnchors) > 0 {
				donatedTokens = readyMsg.ReadyAnchors[len(readyMsg.ReadyAnchors)-1].TokenCount
			}
			s.deps.Telemetry.Cache.SSDDonation("v2", readyMsg.StageMs, donatedTokens)
		}
	} else {
		s.deps.Telemetry.Incr("routing.cache_receipt_rejected", []string{"type:ready_v2", "reason:" + string(receipt.Reason)})
	}
}
