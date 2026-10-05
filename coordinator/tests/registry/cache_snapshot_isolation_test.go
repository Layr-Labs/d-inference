package registry_test

import (
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func cacheTwoModelFixture(t *testing.T, inputs ...production.CacheDependencies) (*cacheObservationFixture, *production.Provider, protocol.PrefixCacheV2Capability, protocol.PrefixCacheV2Capability) {
	t.Helper()
	r, p, a := newCacheObservationFixture(t, inputs...)
	b := a
	b.ModelID = "other-model"
	b.ModelAggregateHash = strings.Repeat("d", 64)
	p.Mu().Lock()
	p.Models = []protocol.ModelInfo{{ID: a.ModelID, WeightHash: a.ModelAggregateHash}, {ID: b.ModelID, WeightHash: b.ModelAggregateHash}}
	p.Mu().Unlock()
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	return r, p, a, b
}

func TestCacheSnapshotOtherModelChangePreservesIssuedReceiptAndHolder(t *testing.T) {
	r, p, a, b := cacheTwoModelFixture(t)
	_, ready := checkpointPricingAttempt(t, r.Registry, p, a, "donor-a", r.plans.bind(exactTestPlan(exactTestAnchor(16, "c"))), 1)
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("initial donation rejected")
	}
	_, next := checkpointPricingAttempt(t, r.Registry, p, a, "next-a", r.plans.bind(exactTestPlan(exactTestAnchor(16, "d"))), 3)
	before := r.config.Holders.Len()
	b.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	if r.config.Holders.Len() != before {
		t.Fatal("unrelated model refresh erased valid holder")
	}
	if !r.ApplyPrefixCacheReadyV2(p.ID, next) {
		t.Fatal("unrelated model refresh erased issued receipt")
	}
}

func TestCacheSnapshotOtherModelCannotClearProofFence(t *testing.T) {
	r, p, a, b := cacheTwoModelFixture(t)
	_, ready := checkpointPricingAttempt(t, r.Registry, p, a, "fenced-donor", r.plans.bind(exactTestPlan(exactTestAnchor(16, "c"))), 1)
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("initial donation rejected")
	}
	r.mismatch(t, p, a, "fenced-mismatch").Apply()
	lifecycle := r.CacheRoutingLifecycleStatus()
	if lifecycle.HolderRemoved[string(cachetracker.RemovalProofMismatch)] != 1 || lifecycle.HolderRemoved[string(cachetracker.RemovalCapabilityChange)] != 0 {
		t.Fatalf("proof rejection misclassified as capability churn: %+v", lifecycle.HolderRemoved)
	}
	b.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	if status := r.CacheRoutingLifecycleStatus(); status.FencedCapabilities != 1 {
		t.Fatalf("other model's heartbeat lifted the fence: %+v", status)
	}
	if _, reason := r.admission.Admit(p.ID, a.ModelID, "ssd"); reason == production.CacheReceiptAccepted {
		t.Fatal("unrelated capability change bypassed proof fence")
	}
}

func TestCacheSnapshotProtocolToggleCannotClearProofFence(t *testing.T) {
	r, p, a, b := cacheTwoModelFixture(t)
	r.mismatch(t, p, a, "toggle-mismatch").Apply()
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 1, nil); err != nil {
		t.Fatal(err)
	}
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}); err != nil {
		t.Fatal(err)
	}
	if _, reason := r.admission.Admit(p.ID, a.ModelID, "ssd"); reason == production.CacheReceiptAccepted {
		t.Fatal("protocol toggle bypassed unchanged proof fence")
	}
}

func TestCacheSnapshotHoldsConnectionOwnershipThroughInvalidation(t *testing.T) {
	var entered atomic.Bool
	r, p, a, b := cacheTwoModelFixture(t, production.CacheDependencies{
		SnapshotCommits: func(commit production.CacheSnapshotCommit) production.CacheSnapshotCommitting {
			return observationSnapshotCommit{commit, &entered}
		},
	})
	entered.Store(false)
	p.Mu().Lock()
	locked := true
	defer func() {
		if locked {
			p.Mu().Unlock()
		}
	}()
	b.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	done := make(chan error, 1)
	go func() { done <- r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{a, b}) }()
	deadline := time.Now().Add(time.Second)
	for !entered.Load() {
		if time.Now().After(deadline) {
			t.Fatal("snapshot released registry ownership while waiting for provider")
		}
		runtime.Gosched()
	}
	writerDone := assertObservationRootOwned(t, r.Registry)
	installed := make(chan struct{})
	go func() {
		r.Disconnect(p.ID)
		r.Register(p.ID, nil, &protocol.RegisterMessage{})
		close(installed)
	}()
	p.Mu().Unlock()
	locked = false
	select {
	case <-writerDone:
	case <-time.After(time.Second):
		t.Fatal("registry writer stalled after snapshot released ownership")
	}
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
