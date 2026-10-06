package trust_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestTrustReuseCacheReuseAndWindow covers the core reuse decision with a fake
// clock: a fresh hardware record with matching identity + binary reuses, and reuse
// expires after the window. Mirrors TestCodeAttestThrottleBudgetAndReuse.
func TestTrustReuseCacheReuseAndWindow(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := trustreuse.New()
	c.Now = func() time.Time { return cur }
	const se, serial = "se-1", "SER-1"

	if _, ok := cachedTrust(c, se, serial, trHashA); ok {
		t.Fatal("no record yet → no reuse")
	}
	if c.HasFreshRecord(se, serial) {
		t.Fatal("no record yet → not a candidate")
	}

	c.RecordTrust(c.PublicationGeneration(), hardwareReuseRecord(se, serial, trHashA, cur))

	if _, ok := cachedTrust(c, se, serial, trHashA); !ok {
		t.Fatal("fresh, matching record must reuse")
	}
	if !c.HasFreshRecord(se, serial) {
		t.Fatal("fresh record must be a candidate")
	}

	cur = cur.Add(c.Window) // window elapsed
	if _, ok := cachedTrust(c, se, serial, trHashA); ok {
		t.Fatal("reuse must expire after the window")
	}
	if c.HasFreshRecord(se, serial) {
		t.Fatal("candidate status must expire after the window")
	}

	// FIX 2 clock-skew guard: a record dated implausibly far in the FUTURE
	// (corrupt/forged VerifiedAt) must be rejected, not treated as eternally fresh.
	future := c.Now().Add(c.Window + time.Minute)
	c.RecordTrust(c.PublicationGeneration(), hardwareReuseRecord(se, serial, trHashA, future))
	if _, ok := cachedTrust(c, se, serial, trHashA); ok {
		t.Fatal("a future-dated record (beyond skew tolerance) must not reuse")
	}
	if c.HasFreshRecord(se, serial) {
		t.Fatal("a future-dated record must not be a candidate")
	}
}

// TestTrustReuseCacheRejectsMismatch pins every record-side gate reuseTrust
// enforces: empty inputs, SE/serial mismatch, binary-hash change, non-hardware
// trust, and bad recorded posture all fail (fall through to full MDM).
func TestTrustReuseCacheRejectsMismatch(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := trustreuse.New()
	c.Now = func() time.Time { return cur }
	const se, serial = "se-1", "SER-1"
	c.RecordTrust(c.PublicationGeneration(), hardwareReuseRecord(se, serial, trHashA, cur))

	if _, ok := cachedTrust(c, "", serial, trHashA); ok {
		t.Fatal("empty SE key must not reuse")
	}
	if _, ok := cachedTrust(c, se, "", trHashA); ok {
		t.Fatal("empty serial must not reuse")
	}
	if _, ok := cachedTrust(c, se, serial, ""); ok {
		t.Fatal("empty fresh binary hash must not reuse")
	}
	if _, ok := cachedTrust(c, "se-OTHER", serial, trHashA); ok {
		t.Fatal("different SE key must not reuse")
	}
	if _, ok := cachedTrust(c, se, "SER-OTHER", trHashA); ok {
		t.Fatal("serial mismatch must not reuse (identity gate)")
	}
	if _, ok := cachedTrust(c, se, serial, trHashB); ok {
		t.Fatal("binary-hash change must not reuse (code-identity gate)")
	}

	// A non-hardware record (e.g. a downgraded write) is never reusable.
	c.RecordTrust(c.PublicationGeneration(), store.ProviderTrustReuse{SEPubKey: "se-ss", Serial: "SER-2", TrustLevel: "self_signed", LastVerifiedBinaryHash: trHashA, SIPEnabled: true, SecureBootFull: true, HardwareProofVerifiedAt: cur})
	if _, ok := cachedTrust(c, "se-ss", "SER-2", trHashA); ok {
		t.Fatal("non-hardware record must not reuse")
	}

	// A record whose recorded posture was not good is never reusable (defensive).
	c.RecordTrust(c.PublicationGeneration(), store.ProviderTrustReuse{SEPubKey: "se-bad", Serial: "SER-3", TrustLevel: string(registry.TrustHardware), LastVerifiedBinaryHash: trHashA, SIPEnabled: true, SecureBootFull: false, HardwareProofVerifiedAt: cur})
	if _, ok := cachedTrust(c, "se-bad", "SER-3", trHashA); ok {
		t.Fatal("record with bad recorded posture must not reuse")
	}
}

func TestTrustReuseDecisionSameBinaryAndApprovedTransition(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	cache := trustreuse.New()
	cache.Now = func() time.Time { return now }
	cache.RecordTrust(cache.PublicationGeneration(), hardwareReuseRecord("se", "SER", trHashA, now))

	same := cache.Decide(trustreuse.Input{
		SEPubKey: "se", Serial: "SER", FreshBinaryHash: trHashA,
	})
	if same.Decision != trustreuse.SameBinary {
		t.Fatalf("same-binary decision = %q", same.Decision)
	}
	rejected := cache.Decide(trustreuse.Input{
		SEPubKey: "se", Serial: "SER", FreshBinaryHash: trHashB,
	})
	if rejected.Reason != trustreuse.TrustReuseReasonTransitionUnapproved {
		t.Fatalf("unapproved transition reason = %q", rejected.Reason)
	}
	approved := cache.Decide(trustreuse.Input{
		SEPubKey: "se", Serial: "SER", FreshBinaryHash: trHashB,
		ReleaseTransition: releases.ApprovedTransitionFact{
			Approved: true, BinaryHash: trHashB,
			ApprovedFromBinaryHashes: map[string]struct{}{trHashA: {}},
		},
	})
	if approved.Decision != trustreuse.ApprovedReleaseTransition {
		t.Fatalf("approved transition decision = %q", approved.Decision)
	}
}

// TestTrustReuseCacheInvalidate proves invalidateReuse drops the record so the
// next reconnect cannot fast-skip. Mirrors the code-attest invalidate behavior.
func TestTrustReuseCacheInvalidate(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := trustreuse.New()
	c.Now = func() time.Time { return cur }
	const se, serial = "se-1", "SER-1"
	c.RecordTrust(c.PublicationGeneration(), hardwareReuseRecord(se, serial, trHashA, cur))
	if _, ok := cachedTrust(c, se, serial, trHashA); !ok {
		t.Fatal("precondition: record should reuse")
	}

	c.InvalidateReuse(se, "cache-invalidate-event")
	if _, ok := cachedTrust(c, se, serial, trHashA); ok {
		t.Fatal("invalidated record must not reuse")
	}
	if c.HasFreshRecord(se, serial) {
		t.Fatal("invalidated record must not be a candidate")
	}
}

func TestSemverPrereleaseTransitionPrecedence(t *testing.T) {
	if !releases.SemverLess("0.8.16-dev.1", "0.8.16") {
		t.Fatal("prerelease-to-stable must be an approved precedence increase")
	}
	if releases.SemverLess("0.8.16", "0.8.16-dev.1") {
		t.Fatal("stable-to-prerelease must never be treated as a non-downgrade")
	}
}

// TestTrustReuseCacheSeed mirrors codeAttestThrottle.seed: only rows within the
// window are seeded, an expired row is skipped, and a fresher in-memory record is
// not overwritten by an older persisted row.
func TestTrustReuseCacheSeed(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := trustreuse.New()
	c.Now = func() time.Time { return cur }

	fresh := hardwareReuseRecord("se-fresh", "SER-F", trHashA, cur.Add(-time.Minute))
	expired := hardwareReuseRecord("se-old", "SER-O", trHashA, cur.Add(-2*c.Window))
	empty := hardwareReuseRecord("", "SER-E", trHashA, cur)
	// FIX 2: a future-dated row (beyond skew tolerance) must be skipped on seed too.
	future := hardwareReuseRecord("se-future", "SER-FU", trHashA, cur.Add(c.Window+time.Minute))

	if n := c.Seed([]store.ProviderTrustReuse{fresh, expired, empty, future}); n != 1 {
		t.Fatalf("seed count = %d, want 1 (only the in-window keyed row)", n)
	}
	if _, ok := cachedTrust(c, "se-fresh", "SER-F", trHashA); !ok {
		t.Fatal("in-window seeded row must reuse")
	}
	if c.HasFreshRecord("se-old", "SER-O") {
		t.Fatal("expired row must not be seeded")
	}
	if c.HasFreshRecord("se-future", "SER-FU") {
		t.Fatal("future-dated row must not be seeded (clock-skew guard)")
	}

	// A newer in-memory record must not be clobbered by an older persisted row.
	c.RecordTrust(c.PublicationGeneration(), hardwareReuseRecord("se-fresh", "SER-F", trHashB, cur)) // newer (cur) + different binary
	older := hardwareReuseRecord("se-fresh", "SER-F", trHashA, cur.Add(-10*time.Minute))
	c.Seed([]store.ProviderTrustReuse{older})
	if _, ok := cachedTrust(c, "se-fresh", "SER-F", trHashB); !ok {
		t.Fatal("seed must not overwrite a fresher in-memory record")
	}
}

// TestTrustReuseWindowFromEnv proves the freshness window is configurable via
// EIGENINFERENCE_TRUST_REUSE_WINDOW and falls back to the reviewed 5-minute
// default otherwise (Threat-Model T-036: the window must not span a SIP-disable
// reboot cycle; tightened from 10m once connection continuity covers the
// legitimate operational reconnects).
func TestTrustReuseWindowFromEnv(t *testing.T) {
	if got := trustreuse.New().Window; got != trustreuse.DefaultWindow {
		t.Fatalf("default window = %s, want %s", got, trustreuse.DefaultWindow)
	}
	if trustreuse.DefaultWindow != 5*time.Minute {
		t.Fatalf("reviewed default window = %s, want exactly 5m", trustreuse.DefaultWindow)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_WINDOW", "45m")
	if got := trustreuse.New().Window; got != 45*time.Minute {
		t.Fatalf("env window = %s, want 45m", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_WINDOW", "garbage")
	if got := trustreuse.New().Window; got != trustreuse.DefaultWindow {
		t.Fatalf("invalid env window = %s, want default %s", got, trustreuse.DefaultWindow)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_WINDOW", "-5m")
	if got := trustreuse.New().Window; got != trustreuse.DefaultWindow {
		t.Fatalf("negative env window = %s, want default %s", got, trustreuse.DefaultWindow)
	}
}

// TestTrustReuseWindowIgnoresRetiredTTLKnob proves the retired
// EIGENINFERENCE_HARDWARE_PROOF_TTL knob cannot widen the fast-skip freshness
// window: a record older than the reviewed 5-minute window never fast-skips,
// regardless of any TTL-style environment value.
func TestTrustReuseWindowIgnoresRetiredTTLKnob(t *testing.T) {
	t.Setenv("EIGENINFERENCE_HARDWARE_PROOF_TTL", "24h")
	cur := time.Unix(1_700_000_000, 0)
	c := trustreuse.New()
	c.Now = func() time.Time { return cur }
	if c.Window != trustreuse.DefaultWindow {
		t.Fatalf("window = %s, want reviewed default %s (retired TTL knob must be ignored)",
			c.Window, trustreuse.DefaultWindow)
	}
	se, serial := "se-ttl-knob", "SER-TTL"
	c.RecordTrust(c.PublicationGeneration(), hardwareReuseRecord(se, serial, trHashA, cur.Add(-11*time.Minute)))
	if c.HasFreshRecord(se, serial) {
		t.Fatal("a record older than the window must not be a fast-skip candidate")
	}
	if result := c.Decide(trustreuse.Input{
		SEPubKey: se, Serial: serial, FreshBinaryHash: trHashA,
	}); result.Decision != "" || result.Reason != trustreuse.ProofExpired {
		t.Fatalf("decision = %q reason = %q, want expired", result.Decision, result.Reason)
	}
}

// TestTrustReuseReconnectGapFromEnv pins the continuity allowance knob: default
// 90s, honored verbatim below the ceiling, HARD-clamped into [0,120s]. The
// 120s ceiling is the RecoveryOS-physics security bound — values above it
// clamp DOWN, never up.
func TestTrustReuseReconnectGapFromEnv(t *testing.T) {
	if got, clamped := trustreuse.TrustReuseReconnectGapFromEnv(); got != trustreuse.DefaultReconnectGap || clamped {
		t.Fatalf("default gap = %s (clamped=%v), want %s unclamped", got, clamped, trustreuse.DefaultReconnectGap)
	}
	if trustreuse.DefaultReconnectGap != 90*time.Second {
		t.Fatalf("reviewed default gap = %s, want 90s", trustreuse.DefaultReconnectGap)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "45s")
	if got, clamped := trustreuse.TrustReuseReconnectGapFromEnv(); got != 45*time.Second || clamped {
		t.Fatalf("env gap = %s (clamped=%v), want 45s unclamped", got, clamped)
	}
	if got := trustreuse.New().ReconnectGap; got != 45*time.Second {
		t.Fatalf("cache gap = %s, want the 45s env value", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "10m")
	if got, clamped := trustreuse.TrustReuseReconnectGapFromEnv(); got != trustreuse.MaxTrustReuseReconnectGap || !clamped {
		t.Fatalf("over-ceiling gap = %s (clamped=%v), want %s clamped DOWN", got, clamped, trustreuse.MaxTrustReuseReconnectGap)
	}
	if got := trustreuse.New().ReconnectGap; got != 120*time.Second {
		t.Fatalf("cache gap = %s, want the 120s security ceiling", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "garbage")
	if got, _ := trustreuse.TrustReuseReconnectGapFromEnv(); got != trustreuse.DefaultReconnectGap {
		t.Fatalf("invalid env gap = %s, want default %s", got, trustreuse.DefaultReconnectGap)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "-30s")
	if got, _ := trustreuse.TrustReuseReconnectGapFromEnv(); got != 0 {
		t.Fatalf("negative env gap = %s, want clamp to 0 (continuity disabled)", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP", "0")
	if got, _ := trustreuse.TrustReuseReconnectGapFromEnv(); got != 0 {
		t.Fatalf("zero env gap = %s, want 0", got)
	}
}
