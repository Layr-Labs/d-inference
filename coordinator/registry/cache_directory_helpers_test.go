package registry

import (
	"fmt"
	"sync/atomic"
	"testing"
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
	if t == nil {
		return false, false
	}
	result := t.directory.ApplyLookup(providerID, provider, capability, msg, routeKey, now)
	return result.Accepted, result.ProofMismatch()
}

func (t *cacheRoutingTracker) applyReadyV2Result(
	providerID string,
	provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheReadyV2Message,
	routeKey []byte,
	now time.Time,
) (bool, bool) {
	if t == nil {
		return false, false
	}
	result := t.directory.ApplyReady(providerID, provider, capability, msg, routeKey, now)
	return result.Accepted, result.ProofMismatch()
}

func (t *cacheRoutingTracker) applyLookupV2(providerID string, capability protocol.PrefixCacheV2Capability, msg *protocol.PrefixCacheLookupV2Message, now time.Time) bool {
	accepted, _ := t.applyLookupV2Result(providerID, nil, capability, msg, []byte("test-cache-route-key"), now)
	return accepted
}
func (t *cacheRoutingTracker) applyReadyV2(providerID string, capability protocol.PrefixCacheV2Capability, msg *protocol.PrefixCacheReadyV2Message, now time.Time) bool {
	accepted, _ := t.applyReadyV2Result(providerID, nil, capability, msg, []byte("test-cache-route-key"), now)
	return accepted
}

var testCacheHolderNonce atomic.Uint64

// Receipt time fixes the requested expiry while the directory performs normal
// proof validation, sequence accounting, holder indexing, and capacity eviction.
func publishTestCacheHolder(t testing.TB, tracker *cacheRoutingTracker, key []byte, plan CachePlan, holder cacheHolder) {
	t.Helper()
	nonce := fmt.Sprintf("holder-%d", testCacheHolderNonce.Add(1))
	now := holder.ExpiresAt.Add(-tracker.directory.Config().TTL)
	cap := testV2Capability(holder.CacheEpoch)
	cap.ModelID, cap.ModelAggregateHash, cap.PromptContractID = holder.ModelID, holder.ModelAggregateHash, holder.PromptContractID
	tracker.directory.RegisterAttempt(nonce, cacheAttempt{RequestID: "request-" + nonce, ProviderID: holder.ProviderID, Provider: holder.Provider, Model: holder.ModelID, ExpiresAt: now.Add(time.Minute), CreatedAt: now, V2: true, Plan: directoryPlan(plan), V2Capability: cap, ExpectedPrompt: holder.Anchor, ExpectedBoundaries: map[int]string{holder.Anchor.TokenCount: holder.Anchor.ChainHash}})
	seq := tracker.directory.LifecycleStatus().SSDLookups + 1
	msg := testV2Lookup(nonce, cap, holder.Anchor, seq)
	msg.Outcome, msg.MatchedAnchor, msg.StageMs = "hit", &holder.Anchor, holder.StageMs
	msg.RequiredRecomputeTokens = holder.RequiredRecomputeTokens
	msg.ExpectedPrefillTokensSaved = holder.Anchor.TokenCount - holder.RequiredRecomputeTokens
	if result := tracker.directory.ApplyLookup(holder.ProviderID, holder.Provider, cap, msg, key, now); !result.Accepted {
		t.Fatalf("holder fixture receipt: %+v", result)
	}
}
