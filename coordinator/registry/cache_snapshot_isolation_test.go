package registry

import (
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func cacheTwoModelFixture(t *testing.T) (*Registry, *Provider, protocol.PrefixCacheV2Capability, protocol.PrefixCacheV2Capability) {
	t.Helper()
	r, p, a := exactTestRegistry(t)
	b := a
	b.ModelID = "other-model"
	b.ModelAggregateHash = strings.Repeat("d", 64)
	p.mu.Lock()
	p.Models = []protocol.ModelInfo{{ID: a.ModelID, WeightHash: a.ModelAggregateHash}, {ID: b.ModelID, WeightHash: b.ModelAggregateHash}}
	p.mu.Unlock()
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	return r, p, a, b
}

func TestCacheSnapshotOtherModelChangePreservesIssuedReceiptAndHolder(t *testing.T) {
	r, p, a, b := cacheTwoModelFixture(t)
	_, ready := checkpointTestAttempt(t, r, p, a, "donor-a", exactTestPlan(exactTestAnchor(16, "c")), 1)
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("initial donation rejected")
	}
	_, next := checkpointTestAttempt(t, r, p, a, "next-a", exactTestPlan(exactTestAnchor(16, "d")), 3)
	before := r.cacheRouting.holderCount
	b.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	if r.cacheRouting.holderCount != before {
		t.Fatal("unrelated model refresh erased valid holder")
	}
	if !r.ApplyPrefixCacheReadyV2(p.ID, next) {
		t.Fatal("unrelated model refresh erased issued receipt")
	}
}

func TestCacheSnapshotOtherModelCannotClearProofFence(t *testing.T) {
	r, p, a, b := cacheTwoModelFixture(t)
	_, ready := checkpointTestAttempt(t, r, p, a, "fenced-donor", exactTestPlan(exactTestAnchor(16, "c")), 1)
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("initial donation rejected")
	}
	r.disablePrefixCacheV2Model(p.ID, a.ModelID, "ssd", p, r.cacheRouting, a)
	lifecycle := r.CacheRoutingLifecycleStatus()
	if lifecycle.HolderRemoved[string(cacheHolderRemovalProofMismatch)] != 1 || lifecycle.HolderRemoved[string(cacheHolderRemovalCapabilityChange)] != 0 {
		t.Fatalf("proof rejection misclassified as capability churn: %+v", lifecycle.HolderRemoved)
	}
	b.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.currentPrefixCacheV2Capability(p.ID, a.ModelID, "ssd"); ok {
		t.Fatal("unrelated capability change bypassed proof fence")
	}
}

func TestCacheSnapshotProtocolToggleCannotClearProofFence(t *testing.T) {
	r, p, a, b := cacheTwoModelFixture(t)
	r.disablePrefixCacheV2Model(p.ID, a.ModelID, "ssd", p, r.cacheRouting, a)
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 1, nil); err != nil {
		t.Fatal(err)
	}
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.currentPrefixCacheV2Capability(p.ID, a.ModelID, "ssd"); ok {
		t.Fatal("protocol toggle bypassed unchanged proof fence")
	}
}

func TestCacheSnapshotHoldsConnectionOwnershipThroughInvalidation(t *testing.T) {
	r, p, a, b := cacheTwoModelFixture(t)
	p.mu.Lock()
	locked := true
	defer func() {
		if locked {
			p.mu.Unlock()
		}
	}()
	b.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	done := make(chan error, 1)
	go func() { done <- r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}) }()
	deadline := time.Now().Add(time.Second)
	for r.mu.TryLock() {
		r.mu.Unlock()
		if time.Now().After(deadline) {
			t.Fatal("snapshot released registry ownership while waiting for provider")
		}
		runtime.Gosched()
	}
	installed := make(chan struct{})
	go func() {
		r.mu.Lock()
		replacement := &Provider{ID: p.ID}
		r.providers[p.ID] = replacement
		r.mu.Unlock()
		close(installed)
	}()
	p.mu.Unlock()
	locked = false
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("snapshot stalled")
	}
	select {
	case <-installed:
	case <-time.After(time.Second):
		t.Fatal("replacement stalled")
	}
}
