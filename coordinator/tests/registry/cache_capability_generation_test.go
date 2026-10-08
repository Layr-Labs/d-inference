package registry_test

import (
	"runtime"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCacheRetiredTrackerCannotRepopulateOrQuarantineReplacement(t *testing.T) {
	r, p, capability := newCacheObservationFixture(t)
	pr, ready := checkpointPricingAttempt(t, r.Registry, p, capability, "old", r.plans.bind(exactTestPlan(exactTestAnchor(16, "c"))), 1)
	old, oldConfig, oldFences := r.core, r.config, r.fences
	quarantine := r.mismatch(t, p, capability, "old-mismatch")
	owner := pr.CacheAttemptSnapshot()
	if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
		t.Fatal(err)
	}
	quarantine.Apply()
	if _, reason := r.admission.Admit(p.ID, "model", "ssd"); reason != production.CacheReceiptAccepted {
		t.Fatal("retired mismatch quarantined replacement generation")
	}
	if r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("old nonce donated into replacement tracker")
	}
	// This retired component has no background caller. Keep the attempted late
	// write and the complete evidence census on the actual retained generation.
	if old.StoreAttemptLocked("late", cachetracker.Attempt[*production.Provider]{ExpiresAt: time.Now().Add(time.Hour)}) {
		t.Error("retired tracker admitted a late insertion")
	}
	if oldConfig.Attempts.Len() != 0 || oldConfig.Holders.Len() != 0 || oldConfig.Sequences.Len() != 0 || oldFences.Len() != 0 {
		t.Error("retired tracker retained or recreated evidence")
	}
	r.MarkCacheAttemptTerminal(pr)
	r.ForgetCacheAttempt(pr)
	_, retained := oldConfig.Attempts.Load(owner.MetadataMessage().CacheReceiptNonce)
	if retained {
		t.Fatal("late cleanup retained old nonce")
	}
	// An old capability result within the current generation cannot quarantine
	// a new provider epoch either.
	currentQuarantine := r.mismatch(t, p, capability, "current-mismatch")
	p.Mu().Lock()
	rotated := capability
	rotated.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	p.PrefixCacheV2Models["model"] = rotated
	r.revisions[p.ID].Advance()
	p.Mu().Unlock()
	currentQuarantine.Apply()
	if current, reason := r.admission.Admit(p.ID, "model", "ssd"); reason != production.CacheReceiptAccepted || current != rotated {
		t.Fatal("old mismatch quarantined new capability epoch")
	}
}

// Pause quarantine at the provider lock. Registry ownership must already be
// held, making connection replacement linearize after the complete mutation.
func TestCacheQuarantineSerializesIdenticalConnectionReplacement(t *testing.T) {
	var entered atomic.Bool
	r, old, capability := newCacheObservationFixture(t, production.CacheDependencies{
		QuarantineCommits: func(commit production.CacheQuarantineCommit) production.CacheQuarantiner {
			return observationQuarantineCommit{commit, &entered}
		},
	})
	quarantine := r.mismatch(t, old, capability, "old-connection-mismatch")
	old.Mu().Lock()
	locked := true
	defer func() {
		if locked {
			old.Mu().Unlock()
		}
	}()
	quarantined := make(chan struct{})
	go func() {
		quarantine.Apply()
		close(quarantined)
	}()
	deadline := time.Now().Add(time.Second)
	for !entered.Load() {
		if time.Now().After(deadline) {
			t.Fatal("quarantine released registry ownership before waiting for captured provider")
		}
		runtime.Gosched()
	}
	writerDone := assertObservationRootOwned(t, r.Registry)
	var replacement *production.Provider
	installed := make(chan struct{})
	go func() {
		r.Disconnect(old.ID)
		replacement = r.Register(old.ID, nil, &protocol.RegisterMessage{PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability}})
		close(installed)
	}()
	old.Mu().Unlock()
	locked = false
	select {
	case <-writerDone:
	case <-time.After(time.Second):
		t.Fatal("registry writer stalled after quarantine released ownership")
	}
	for _, done := range []chan struct{}{quarantined, installed} {
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("quarantine/connection replacement lock order stalled")
		}
	}
	// Even an identical persisted capability belongs to the new connection.
	if got, reason := r.admission.Admit(old.ID, "model", "ssd"); reason != production.CacheReceiptAccepted || got != capability {
		t.Fatal("old mismatch poisoned the replacement connection")
	}
	quarantine.Apply()
	if _, reason := r.admission.Admit(old.ID, "model", "ssd"); reason != production.CacheReceiptAccepted {
		t.Fatal("late old callback poisoned the replacement connection")
	}
	r.mismatch(t, replacement, capability, "replacement-mismatch").Apply()
	if _, reason := r.admission.Admit(old.ID, "model", "ssd"); reason == production.CacheReceiptAccepted {
		t.Fatal("current-connection mismatch no longer quarantines")
	}
}
