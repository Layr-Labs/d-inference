package trustreuse

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"testing"
	"time"
)

// TestTrustReuseCacheReuseAndWindow covers the core reuse decision with a fake
// clock: a fresh hardware record with matching identity + binary reuses, and reuse
// expires after the window. Mirrors TestCodeAttestThrottleBudgetAndReuse.
func TestTrustReuseCacheReuseAndWindow(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := newCache()
	c.now = func() time.Time { return cur }
	const se, serial = "se-1", "SER-1"

	if _, ok := c.reuse(se, serial, trHashA); ok {
		t.Fatal("no record yet → no reuse")
	}
	if c.hasFreshRecord(se, serial) {
		t.Fatal("no record yet → not a candidate")
	}

	c.recordTrust(hardwareReuseRecord(se, serial, trHashA, cur))

	if _, ok := c.reuse(se, serial, trHashA); !ok {
		t.Fatal("fresh, matching record must reuse")
	}
	if !c.hasFreshRecord(se, serial) {
		t.Fatal("fresh record must be a candidate")
	}

	cur = cur.Add(c.reuseWindow) // window elapsed
	if _, ok := c.reuse(se, serial, trHashA); ok {
		t.Fatal("reuse must expire after the window")
	}
	if c.hasFreshRecord(se, serial) {
		t.Fatal("candidate status must expire after the window")
	}

	// FIX 2 clock-skew guard: a record dated implausibly far in the FUTURE
	// (corrupt/forged VerifiedAt) must be rejected, not treated as eternally fresh.
	future := c.now().Add(c.reuseWindow + time.Minute)
	c.recordTrust(hardwareReuseRecord(se, serial, trHashA, future))
	if _, ok := c.reuse(se, serial, trHashA); ok {
		t.Fatal("a future-dated record (beyond skew tolerance) must not reuse")
	}
	if c.hasFreshRecord(se, serial) {
		t.Fatal("a future-dated record must not be a candidate")
	}
}

// TestTrustReuseCacheRejectsMismatch pins every record-side gate reuseTrust
// enforces: empty inputs, SE/serial mismatch, binary-hash change, non-hardware
// trust, and bad recorded posture all fail (fall through to full MDM).
func TestTrustReuseCacheRejectsMismatch(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := newCache()
	c.now = func() time.Time { return cur }
	const se, serial = "se-1", "SER-1"
	c.recordTrust(hardwareReuseRecord(se, serial, trHashA, cur))

	if _, ok := c.reuse("", serial, trHashA); ok {
		t.Fatal("empty SE key must not reuse")
	}
	if _, ok := c.reuse(se, "", trHashA); ok {
		t.Fatal("empty serial must not reuse")
	}
	if _, ok := c.reuse(se, serial, ""); ok {
		t.Fatal("empty fresh binary hash must not reuse")
	}
	if _, ok := c.reuse("se-OTHER", serial, trHashA); ok {
		t.Fatal("different SE key must not reuse")
	}
	if _, ok := c.reuse(se, "SER-OTHER", trHashA); ok {
		t.Fatal("serial mismatch must not reuse (identity gate)")
	}
	if _, ok := c.reuse(se, serial, trHashB); ok {
		t.Fatal("binary-hash change must not reuse (code-identity gate)")
	}

	// A non-hardware record (e.g. a downgraded write) is never reusable.
	c.recordTrust(store.ProviderTrustReuse{SEPubKey: "se-ss", Serial: "SER-2", TrustLevel: "self_signed", LastVerifiedBinaryHash: trHashA, SIPEnabled: true, SecureBootFull: true, HardwareProofVerifiedAt: cur})
	if _, ok := c.reuse("se-ss", "SER-2", trHashA); ok {
		t.Fatal("non-hardware record must not reuse")
	}

	// A record whose recorded posture was not good is never reusable (defensive).
	c.recordTrust(store.ProviderTrustReuse{SEPubKey: "se-bad", Serial: "SER-3", TrustLevel: string(registry.TrustHardware), LastVerifiedBinaryHash: trHashA, SIPEnabled: true, SecureBootFull: false, HardwareProofVerifiedAt: cur})
	if _, ok := c.reuse("se-bad", "SER-3", trHashA); ok {
		t.Fatal("record with bad recorded posture must not reuse")
	}
}

func TestTrustReuseDecisionSameBinaryAndApprovedTransition(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	cache := newCache()
	cache.now = func() time.Time { return now }
	cache.recordTrust(hardwareReuseRecord("se", "SER", trHashA, now))

	same := cache.decide(Input{
		SEPubKey: "se", Serial: "SER", FreshBinaryHash: trHashA,
	})
	if same.Decision != DecisionSameBinary {
		t.Fatalf("same-binary decision = %q", same.Decision)
	}
	rejected := cache.decide(Input{
		SEPubKey: "se", Serial: "SER", FreshBinaryHash: trHashB,
	})
	if rejected.Reason != ReasonTransitionUnapproved {
		t.Fatalf("unapproved transition reason = %q", rejected.Reason)
	}
	approved := cache.decide(Input{
		SEPubKey: "se", Serial: "SER", FreshBinaryHash: trHashB,
		ReleaseTransition: ReleaseTransition{
			Approved: true, BinaryHash: trHashB,
			ApprovedFromBinaryHashes: map[string]struct{}{trHashA: {}},
		},
	})
	if approved.Decision != DecisionApprovedReleaseTransition {
		t.Fatalf("approved transition decision = %q", approved.Decision)
	}
}

// TestTrustReuseCacheInvalidate proves invalidateReuse drops the record so the
// next reconnect cannot fast-skip. Mirrors the code-attest invalidate behavior.
func TestTrustReuseCacheInvalidate(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := newCache()
	c.now = func() time.Time { return cur }
	const se, serial = "se-1", "SER-1"
	c.recordTrust(hardwareReuseRecord(se, serial, trHashA, cur))
	if _, ok := c.reuse(se, serial, trHashA); !ok {
		t.Fatal("precondition: record should reuse")
	}

	c.invalidateReuse(se, "cache-invalidate-event")
	if _, ok := c.reuse(se, serial, trHashA); ok {
		t.Fatal("invalidated record must not reuse")
	}
	if c.hasFreshRecord(se, serial) {
		t.Fatal("invalidated record must not be a candidate")
	}
}

// TestTrustReuseCacheSeed mirrors codeAttestThrottle.seed: only rows within the
// window are seeded, an expired row is skipped, and a fresher in-memory record is
// not overwritten by an older persisted row.
func TestTrustReuseCacheSeed(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := newCache()
	c.now = func() time.Time { return cur }

	fresh := hardwareReuseRecord("se-fresh", "SER-F", trHashA, cur.Add(-time.Minute))
	expired := hardwareReuseRecord("se-old", "SER-O", trHashA, cur.Add(-2*c.reuseWindow))
	empty := hardwareReuseRecord("", "SER-E", trHashA, cur)
	// FIX 2: a future-dated row (beyond skew tolerance) must be skipped on seed too.
	future := hardwareReuseRecord("se-future", "SER-FU", trHashA, cur.Add(c.reuseWindow+time.Minute))

	if n := c.seed([]store.ProviderTrustReuse{fresh, expired, empty, future}); n != 1 {
		t.Fatalf("seed count = %d, want 1 (only the in-window keyed row)", n)
	}
	if _, ok := c.reuse("se-fresh", "SER-F", trHashA); !ok {
		t.Fatal("in-window seeded row must reuse")
	}
	if c.hasFreshRecord("se-old", "SER-O") {
		t.Fatal("expired row must not be seeded")
	}
	if c.hasFreshRecord("se-future", "SER-FU") {
		t.Fatal("future-dated row must not be seeded (clock-skew guard)")
	}

	// A newer in-memory record must not be clobbered by an older persisted row.
	c.recordTrust(hardwareReuseRecord("se-fresh", "SER-F", trHashB, cur)) // newer (cur) + different binary
	older := hardwareReuseRecord("se-fresh", "SER-F", trHashA, cur.Add(-10*time.Minute))
	c.seed([]store.ProviderTrustReuse{older})
	if _, ok := c.reuse("se-fresh", "SER-F", trHashB); !ok {
		t.Fatal("seed must not overwrite a fresher in-memory record")
	}
}

// TestTrustReuseWindowFromEnv proves the freshness window is configurable via
// EIGENINFERENCE_TRUST_REUSE_WINDOW and falls back to the reviewed 5-minute
// default otherwise (Threat-Model T-036: the window must not span a SIP-disable
// reboot cycle; tightened from 10m once connection continuity covers the
// legitimate operational reconnects).
func TestTrustReuseWindowFromEnv(t *testing.T) {
	if got := newCache().reuseWindow; got != defaultTrustReuseWindow {
		t.Fatalf("default window = %s, want %s", got, defaultTrustReuseWindow)
	}
	if defaultTrustReuseWindow != 5*time.Minute {
		t.Fatalf("reviewed default window = %s, want exactly 5m", defaultTrustReuseWindow)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_WINDOW", "45m")
	if got := newCache().reuseWindow; got != 45*time.Minute {
		t.Fatalf("env window = %s, want 45m", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_WINDOW", "garbage")
	if got := newCache().reuseWindow; got != defaultTrustReuseWindow {
		t.Fatalf("invalid env window = %s, want default %s", got, defaultTrustReuseWindow)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_WINDOW", "-5m")
	if got := newCache().reuseWindow; got != defaultTrustReuseWindow {
		t.Fatalf("negative env window = %s, want default %s", got, defaultTrustReuseWindow)
	}
}

// TestTrustReuseWindowIgnoresRetiredTTLKnob proves the retired
// EIGENINFERENCE_HARDWARE_PROOF_TTL knob cannot widen the fast-skip freshness
// window: a record older than the reviewed 5-minute window never fast-skips,
// regardless of any TTL-style environment value.
func TestTrustReuseWindowIgnoresRetiredTTLKnob(t *testing.T) {
	t.Setenv("EIGENINFERENCE_HARDWARE_PROOF_TTL", "24h")
	cur := time.Unix(1_700_000_000, 0)
	c := newCache()
	c.now = func() time.Time { return cur }
	if c.reuseWindow != defaultTrustReuseWindow {
		t.Fatalf("window = %s, want reviewed default %s (retired TTL knob must be ignored)",
			c.reuseWindow, defaultTrustReuseWindow)
	}
	se, serial := "se-ttl-knob", "SER-TTL"
	c.recordTrust(hardwareReuseRecord(se, serial, trHashA, cur.Add(-11*time.Minute)))
	if c.hasFreshRecord(se, serial) {
		t.Fatal("a record older than the window must not be a fast-skip candidate")
	}
	if result := c.decide(Input{
		SEPubKey: se, Serial: serial, FreshBinaryHash: trHashA,
	}); result.Decision != "" || result.Reason != ReasonProofExpired {
		t.Fatalf("decision = %q reason = %q, want expired", result.Decision, result.Reason)
	}
}

// TestSeedTrustReuseCacheWiresHookWithoutStore proves FIX 5: SeedTrustReuseCache
// wires the hard-untrust invalidation hook even when no store is available for
// persistence/seeding, so a hard untrust still drops the in-memory record (under
// the memory-store fallback the in-memory cache must stay correct).
func TestSeedTrustReuseCacheWiresHookWithoutStore(t *testing.T) {
	logger := quietLogger()
	srv := newTestManager(registry.New(logger), store.NewMemory(store.Config{}), Config{}, logger)
	// Simulate "no store wired for persistence/seeding". The hook must STILL be
	// wired (decoupled from the store) by SeedTrustReuseCache.
	srv.store = nil
	srv.SeedTrustReuseCache(context.Background())

	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", PublicKey: testPublicKeyB64(),
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	}
	p := srv.registry.Register("prov-nostore", nil, msg)
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "SER-NS", PublicKey: "se-nostore"}
	p.Mu().Unlock()
	srv.cache.recordTrust(hardwareReuseRecord("se-nostore", "SER-NS", trHashA, time.Now()))

	srv.registry.MarkUntrusted("prov-nostore") // hard untrust → hook must fire even w/o store

	if srv.cache.hasFreshRecord("se-nostore", "SER-NS") {
		t.Fatal("hard untrust must invalidate the in-memory record even with no store wired (FIX 5 decoupling)")
	}
}

// TestTrustReuseReconnectGapFromEnv pins the continuity allowance knob: default
// 90s, honored verbatim below the ceiling, HARD-clamped into [0,120s]. The
// 120s ceiling is the RecoveryOS-physics security bound — values above it
// clamp DOWN, never up.
func TestTrustReuseReconnectGapFromEnv(t *testing.T) {
	if got, clamped := trustReuseReconnectGapFromEnv(); got != defaultTrustReuseReconnectGap || clamped {
		t.Fatalf("default gap = %s (clamped=%v), want %s unclamped", got, clamped, defaultTrustReuseReconnectGap)
	}
	if defaultTrustReuseReconnectGap != 90*time.Second {
		t.Fatalf("reviewed default gap = %s, want 90s", defaultTrustReuseReconnectGap)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "45s")
	if got, clamped := trustReuseReconnectGapFromEnv(); got != 45*time.Second || clamped {
		t.Fatalf("env gap = %s (clamped=%v), want 45s unclamped", got, clamped)
	}
	if got := newCache().reconnectGap; got != 45*time.Second {
		t.Fatalf("cache gap = %s, want the 45s env value", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "10m")
	if got, clamped := trustReuseReconnectGapFromEnv(); got != maxTrustReuseReconnectGap || !clamped {
		t.Fatalf("over-ceiling gap = %s (clamped=%v), want %s clamped DOWN", got, clamped, maxTrustReuseReconnectGap)
	}
	if got := newCache().reconnectGap; got != 120*time.Second {
		t.Fatalf("cache gap = %s, want the 120s security ceiling", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "garbage")
	if got, _ := trustReuseReconnectGapFromEnv(); got != defaultTrustReuseReconnectGap {
		t.Fatalf("invalid env gap = %s, want default %s", got, defaultTrustReuseReconnectGap)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "-30s")
	if got, _ := trustReuseReconnectGapFromEnv(); got != 0 {
		t.Fatalf("negative env gap = %s, want clamp to 0 (continuity disabled)", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "0")
	if got, _ := trustReuseReconnectGapFromEnv(); got != 0 {
		t.Fatalf("zero env gap = %s, want 0", got)
	}
}
