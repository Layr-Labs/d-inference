package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"runtime"
	"testing"
	"time"
)

func TestCacheRetiredTrackerCannotRepopulateOrQuarantineReplacement(t *testing.T) {
	r, p, capability := exactTestRegistry(t)
	pr, ready := checkpointTestAttempt(t, r, p, capability, "old", exactTestPlan(exactTestAnchor(16, "c")), 1)
	old := r.cacheRouting
	metadata, _ := pr.CacheAttemptSnapshot().Metadata()
	if err := r.ConfigureCacheRouting(generationTestConfig(CacheRoutingOn)); err != nil {
		t.Fatal(err)
	}
	r.disablePrefixCacheV2Model(p.ID, "model", "ssd", p, old, capability)
	if _, ok := r.currentPrefixCacheV2Capability(p.ID, "model", "ssd"); !ok {
		t.Fatal("retired mismatch quarantined replacement generation")
	}
	if r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("old nonce donated into replacement tracker")
	}

	old.directory.RegisterAttempt("late", cacheAttempt{ExpiresAt: time.Now().Add(time.Hour)})
	if old.directory.Snapshot().Attempts != 0 || old.directory.Snapshot().Holders != 0 || old.directory.Snapshot().Sequences != 0 || old.directory.Snapshot().Rejected != 0 {
		t.Error("retired tracker retained or recreated evidence")
	}

	r.MarkCacheAttemptTerminal(pr)
	r.ForgetCacheAttempt(pr)

	_, retained := old.directory.AttemptDeadline(metadata.Nonce)

	if retained {
		t.Fatal("late cleanup retained old nonce")
	}
	// An old capability result within the current generation cannot quarantine
	// a new provider epoch either.
	p.mu.Lock()
	rotated := capability
	rotated.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	p.PrefixCacheV2Models["model"] = rotated
	p.prefixCacheRevision++
	p.mu.Unlock()
	r.disablePrefixCacheV2Model(p.ID, "model", "ssd", p, r.cacheRouting, capability)
	if current, ok := r.currentPrefixCacheV2Capability(p.ID, "model", "ssd"); !ok || current != rotated {
		t.Fatal("old mismatch quarantined new capability epoch")
	}
}

// Pause quarantine at the provider lock. Registry ownership must already be
// held, making connection replacement linearize after the complete mutation.
func TestCacheQuarantineSerializesIdenticalConnectionReplacement(t *testing.T) {
	r, old, capability := exactTestRegistry(t)
	tracker := r.cacheRouting
	old.mu.Lock()
	locked := true
	defer func() {
		if locked {
			old.mu.Unlock()
		}
	}()
	quarantined := make(chan struct{})
	go func() {
		r.disablePrefixCacheV2Model(old.ID, "model", "ssd", old, tracker, capability)
		close(quarantined)
	}()
	deadline := time.Now().Add(time.Second)
	for r.mu.TryLock() {
		r.mu.Unlock()
		if time.Now().After(deadline) {
			t.Fatal("quarantine released registry ownership before waiting for captured provider")
		}
		runtime.Gosched()
	}
	replacement := &Provider{ID: old.ID, PrefixCacheProtocol: 2, PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{"model": capability}}
	installed := make(chan struct{})
	go func() {
		r.mu.Lock()
		r.providers[old.ID] = replacement
		r.mu.Unlock()
		tracker.directory.Disconnect(old.ID, cacheHolderRemovalDisconnect)
		close(installed)
	}()
	old.mu.Unlock()
	locked = false
	for _, done := range []chan struct{}{quarantined, installed} {
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("quarantine/connection replacement lock order stalled")
		}
	}
	// Even an identical persisted capability belongs to the new connection.
	if got, ok := r.currentPrefixCacheV2Capability(old.ID, "model", "ssd"); !ok || got != capability {
		t.Fatal("old mismatch poisoned the replacement connection")
	}
	r.disablePrefixCacheV2Model(old.ID, "model", "ssd", old, tracker, capability)
	if _, ok := r.currentPrefixCacheV2Capability(old.ID, "model", "ssd"); !ok {
		t.Fatal("late old callback poisoned the replacement connection")
	}
	r.disablePrefixCacheV2Model(old.ID, "model", "ssd", replacement, tracker, capability)
	if _, ok := r.currentPrefixCacheV2Capability(old.ID, "model", "ssd"); ok {
		t.Fatal("current-connection mismatch no longer quarantines")
	}
}
