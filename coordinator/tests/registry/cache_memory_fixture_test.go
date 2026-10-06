package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Pause the real disconnect between directory removal and evidence cleanup so
// replacement identity is checked while the old connection's holder still lives.
type pausedMemoryInvalidation struct {
	production.CacheMaintainer
	entered chan struct{}
	release chan struct{}
}

func (m *pausedMemoryInvalidation) InvalidateProviderEvidence(id string, reason cachetracker.RemovalReason, preserveFences bool) {
	if id == "memory" {
		close(m.entered)
		<-m.release
	}
	m.CacheMaintainer.InvalidateProviderEvidence(id, reason, preserveFences)
}

func memoryTestProvider(t *testing.T, r *production.Registry, id string, capability protocol.PrefixCacheV2Capability) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, id, "model", 100)
	p.Mu().Lock()
	p.PrefillTPS = 100
	p.Models[0].WeightHash = capability.ModelAggregateHash
	p.PrefixCacheProtocol = 2
	p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
	p.Mu().Unlock()
	return p
}

func memoryTestAttempt(t *testing.T, r *production.Registry, provider *production.Provider, capability protocol.PrefixCacheV2Capability, requestID string, plan production.CachePlan, seq uint64) (*production.PendingRequest, *protocol.PrefixCacheReadyV2Message) {
	t.Helper()
	pr := &production.PendingRequest{RequestID: requestID, Model: "model", CachePlan: plan}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	metadata := pr.CacheAttemptSnapshot().MetadataMessage()
	if metadata.CacheReceiptNonce == "" || !pr.CacheRoutingParticipates() {
		t.Fatal("resident-only capability did not receive an authenticated attempt")
	}
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	lookup := fenceTestV2Lookup(metadata.CacheReceiptNonce, capability, prompt, seq)
	lookup.RequestID, lookup.Tier = requestID, "memory"
	if !r.ApplyPrefixCacheLookupV2(provider.ID, lookup) {
		t.Fatal("resident lookup rejected")
	}
	ready := fenceTestV2Ready(metadata.CacheReceiptNonce, capability, prompt, seq+1)
	ready.RequestID, ready.Tier = requestID, "memory"
	return pr, ready
}
