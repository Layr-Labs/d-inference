package registry

import (
	"encoding/base64"
	"testing"
	"time"
)

// TestCacheAttemptTerminalAndForgetSkipRegistryLockWithoutNonce pins that the
// terminal (RemovePending → MarkCacheAttemptTerminal) and forget
// (PrepareCacheAttempt → ForgetCacheAttempt) paths never touch Registry.mu when
// the request carries no receipt nonce — the shape of every request while cache
// routing is off, and of every v0/v1 attempt while it is on. Registry.mu is the
// write-contended routing lock: an RLock there queues behind pending writers.
// The test holds the write lock and requires both calls to complete anyway.
// Fails before the change: both paths RLock r.mu before the empty-nonce check
// and block until the test's deadline.
func TestCacheAttemptTerminalAndForgetSkipRegistryLockWithoutNonce(t *testing.T) {
	reg := New(testLogger())
	provider := makeSchedulerProvider(t, reg, "provider", "model", 50)
	pr := &PendingRequest{RequestID: "req", Model: "model", RequestedMaxTokens: 64}
	provider.mu.Lock()
	provider.addPendingLocked(pr)
	provider.mu.Unlock()
	// A protocol-0 attempt carries a buster and participation flag but no
	// nonce; the forget path must still clear both without the lock.
	pr.LegacyCacheBustKey = legacyCacheBustPrefix + "stale"
	pr.setCacheRoutingParticipates(true)

	reg.mu.Lock()
	done := make(chan *PendingRequest, 1)
	go func() {
		removed := provider.RemovePending(pr.RequestID)
		reg.ForgetCacheAttempt(pr)
		done <- removed
	}()
	select {
	case removed := <-done:
		if removed != pr {
			t.Fatalf("RemovePending returned %+v, want the registered request", removed)
		}
	case <-time.After(5 * time.Second):
		reg.mu.Unlock()
		t.Fatal("RemovePending/ForgetCacheAttempt blocked behind a held Registry.mu write lock")
	}
	reg.mu.Unlock()

	if pr.LegacyCacheBustKey != "" || pr.CacheRoutingParticipates() {
		t.Fatalf("ForgetCacheAttempt skipped its field resets: bust=%q participates=%v",
			pr.LegacyCacheBustKey, pr.CacheRoutingParticipates())
	}
	if pr.CacheReceiptNonce != "" || pr.CacheScope != "" || pr.PrefixCacheProtocol != 0 {
		t.Fatalf("ForgetCacheAttempt left attempt state: %+v", pr)
	}

	// Ceiling, not the regression: the nonce-free path is allocation-free.
	if allocs := testing.AllocsPerRun(1000, func() {
		reg.MarkCacheAttemptTerminal(pr)
		reg.ForgetCacheAttempt(pr)
	}); allocs != 0 {
		t.Fatalf("nonce-free terminal+forget allocated %v/op, want 0", allocs)
	}
}

// TestCacheRoutingActiveTracksConfiguredMode pins the lock-free mirror of the
// cache-routing mode that the request path consults before any sidecar or
// registry work: false on a nil or fresh registry, true only after
// ConfigureCacheRouting(on), reset on every transition, and untouched by a
// rejected configuration.
func TestCacheRoutingActiveTracksConfiguredMode(t *testing.T) {
	var nilReg *Registry
	if nilReg.CacheRoutingActive() {
		t.Fatal("nil registry reported cache routing active")
	}
	reg := New(testLogger())
	if reg.CacheRoutingActive() {
		t.Fatal("fresh registry reported cache routing active; the default mode is off")
	}
	cfg := CacheRoutingConfig{
		Mode: CacheRoutingOn, ActivationPct: 100, TTL: time.Minute, MaxHolders: 4,
		MaxDiscountMs: 1000, MaxCostFraction: .35,
		MasterKey: base64.RawURLEncoding.EncodeToString(
			[]byte("0123456789abcdef0123456789abcdef")),
	}
	if err := reg.ConfigureCacheRouting(cfg); err != nil {
		t.Fatal(err)
	}
	if !reg.CacheRoutingActive() || reg.CacheRoutingConfigSnapshot().Mode != CacheRoutingOn {
		t.Fatal("mode=on did not arm cache routing")
	}
	invalid := cfg
	invalid.Mode = "shadow"
	if err := reg.ConfigureCacheRouting(invalid); err == nil {
		t.Fatal("invalid mode was accepted")
	}
	if !reg.CacheRoutingActive() {
		t.Fatal("rejected configuration disarmed cache routing")
	}
	cfg.Mode = CacheRoutingOff
	if err := reg.ConfigureCacheRouting(cfg); err != nil {
		t.Fatal(err)
	}
	if reg.CacheRoutingActive() || reg.CacheRoutingConfigSnapshot().Mode != CacheRoutingOff {
		t.Fatal("mode=off did not disarm cache routing")
	}
}
