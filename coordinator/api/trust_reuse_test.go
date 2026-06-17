package api

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// flakyDeleteStore wraps a real store and fails the first failFirst calls to
// DeleteProviderTrustReuse, then delegates. Used to prove the inline bounded retry
// in invalidateTrustReuse (DAR-326 FIX 1) ultimately deletes the persisted row.
type flakyDeleteStore struct {
	store.Store
	mu          sync.Mutex
	failFirst   int
	deleteCalls int
}

func (f *flakyDeleteStore) DeleteProviderTrustReuse(ctx context.Context, seKey string) error {
	f.mu.Lock()
	f.deleteCalls++
	n := f.deleteCalls
	f.mu.Unlock()
	if n <= f.failFirst {
		return fmt.Errorf("simulated transient delete failure #%d", n)
	}
	return f.Store.DeleteProviderTrustReuse(ctx, seKey)
}

func (f *flakyDeleteStore) calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.deleteCalls
}

// Two distinct, valid 64-char SHA-256 hex digests for binary-hash gate tests.
var (
	trHashA = strings.Repeat("a", 64)
	trHashB = strings.Repeat("b", 64)
)

func trBoolPtr(b bool) *bool { return &b }

// hardwareReuseRecord builds a fresh, all-gates-good record for the given device.
func hardwareReuseRecord(seKey, serial, binaryHash string, at time.Time) store.ProviderTrustReuse {
	return store.ProviderTrustReuse{
		SEPubKey:       seKey,
		Serial:         serial,
		TrustLevel:     string(registry.TrustHardware),
		BinaryHash:     binaryHash,
		SIPEnabled:     true,
		SecureBootFull: true,
		MDAUDID:        "UDID-1",
		VerifiedAt:     at,
	}
}

// TestTrustReuseCacheReuseAndWindow covers the core reuse decision with a fake
// clock: a fresh hardware record with matching identity + binary reuses, and reuse
// expires after the window. Mirrors TestCodeAttestThrottleBudgetAndReuse.
func TestTrustReuseCacheReuseAndWindow(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := newTrustReuseCache()
	c.now = func() time.Time { return cur }
	const se, serial = "se-1", "SER-1"

	if _, ok := c.reuseTrust(se, serial, trHashA); ok {
		t.Fatal("no record yet → no reuse")
	}
	if c.hasFreshRecord(se, serial) {
		t.Fatal("no record yet → not a candidate")
	}

	c.recordTrust(hardwareReuseRecord(se, serial, trHashA, cur))

	if _, ok := c.reuseTrust(se, serial, trHashA); !ok {
		t.Fatal("fresh, matching record must reuse")
	}
	if !c.hasFreshRecord(se, serial) {
		t.Fatal("fresh record must be a candidate")
	}

	cur = cur.Add(c.reuseWindow) // window elapsed
	if _, ok := c.reuseTrust(se, serial, trHashA); ok {
		t.Fatal("reuse must expire after the window")
	}
	if c.hasFreshRecord(se, serial) {
		t.Fatal("candidate status must expire after the window")
	}

	// FIX 2 clock-skew guard: a record dated implausibly far in the FUTURE
	// (corrupt/forged VerifiedAt) must be rejected, not treated as eternally fresh.
	future := c.now().Add(c.reuseWindow + time.Minute)
	c.recordTrust(hardwareReuseRecord(se, serial, trHashA, future))
	if _, ok := c.reuseTrust(se, serial, trHashA); ok {
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
	c := newTrustReuseCache()
	c.now = func() time.Time { return cur }
	const se, serial = "se-1", "SER-1"
	c.recordTrust(hardwareReuseRecord(se, serial, trHashA, cur))

	if _, ok := c.reuseTrust("", serial, trHashA); ok {
		t.Fatal("empty SE key must not reuse")
	}
	if _, ok := c.reuseTrust(se, "", trHashA); ok {
		t.Fatal("empty serial must not reuse")
	}
	if _, ok := c.reuseTrust(se, serial, ""); ok {
		t.Fatal("empty fresh binary hash must not reuse")
	}
	if _, ok := c.reuseTrust("se-OTHER", serial, trHashA); ok {
		t.Fatal("different SE key must not reuse")
	}
	if _, ok := c.reuseTrust(se, "SER-OTHER", trHashA); ok {
		t.Fatal("serial mismatch must not reuse (identity gate)")
	}
	if _, ok := c.reuseTrust(se, serial, trHashB); ok {
		t.Fatal("binary-hash change must not reuse (code-identity gate)")
	}

	// A non-hardware record (e.g. a downgraded write) is never reusable.
	c.recordTrust(store.ProviderTrustReuse{SEPubKey: "se-ss", Serial: "SER-2", TrustLevel: "self_signed", BinaryHash: trHashA, SIPEnabled: true, SecureBootFull: true, VerifiedAt: cur})
	if _, ok := c.reuseTrust("se-ss", "SER-2", trHashA); ok {
		t.Fatal("non-hardware record must not reuse")
	}

	// A record whose recorded posture was not good is never reusable (defensive).
	c.recordTrust(store.ProviderTrustReuse{SEPubKey: "se-bad", Serial: "SER-3", TrustLevel: string(registry.TrustHardware), BinaryHash: trHashA, SIPEnabled: true, SecureBootFull: false, VerifiedAt: cur})
	if _, ok := c.reuseTrust("se-bad", "SER-3", trHashA); ok {
		t.Fatal("record with bad recorded posture must not reuse")
	}
}

// TestTrustReuseCacheInvalidate proves invalidateReuse drops the record so the
// next reconnect cannot fast-skip. Mirrors the code-attest invalidate behavior.
func TestTrustReuseCacheInvalidate(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := newTrustReuseCache()
	c.now = func() time.Time { return cur }
	const se, serial = "se-1", "SER-1"
	c.recordTrust(hardwareReuseRecord(se, serial, trHashA, cur))
	if _, ok := c.reuseTrust(se, serial, trHashA); !ok {
		t.Fatal("precondition: record should reuse")
	}
	c.invalidateReuse(se)
	if _, ok := c.reuseTrust(se, serial, trHashA); ok {
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
	c := newTrustReuseCache()
	c.now = func() time.Time { return cur }

	fresh := hardwareReuseRecord("se-fresh", "SER-F", trHashA, cur.Add(-time.Minute))
	expired := hardwareReuseRecord("se-old", "SER-O", trHashA, cur.Add(-2*c.reuseWindow))
	empty := hardwareReuseRecord("", "SER-E", trHashA, cur)
	// FIX 2: a future-dated row (beyond skew tolerance) must be skipped on seed too.
	future := hardwareReuseRecord("se-future", "SER-FU", trHashA, cur.Add(c.reuseWindow+time.Minute))

	if n := c.seed([]store.ProviderTrustReuse{fresh, expired, empty, future}); n != 1 {
		t.Fatalf("seed count = %d, want 1 (only the in-window keyed row)", n)
	}
	if _, ok := c.reuseTrust("se-fresh", "SER-F", trHashA); !ok {
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
	if _, ok := c.reuseTrust("se-fresh", "SER-F", trHashB); !ok {
		t.Fatal("seed must not overwrite a fresher in-memory record")
	}
}

// TestTrustReuseWindowFromEnv proves the freshness window is configurable via
// EIGENINFERENCE_TRUST_REUSE_WINDOW and falls back to the default otherwise.
func TestTrustReuseWindowFromEnv(t *testing.T) {
	if got := newTrustReuseCache().reuseWindow; got != defaultTrustReuseWindow {
		t.Fatalf("default window = %s, want %s", got, defaultTrustReuseWindow)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_WINDOW", "45m")
	if got := newTrustReuseCache().reuseWindow; got != 45*time.Minute {
		t.Fatalf("env window = %s, want 45m", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_WINDOW", "garbage")
	if got := newTrustReuseCache().reuseWindow; got != defaultTrustReuseWindow {
		t.Fatalf("invalid env window = %s, want default %s", got, defaultTrustReuseWindow)
	}
}

// --- Server-level store integration (seed / write-through / invalidate) ---

func trustReuseServer(t *testing.T) (*Server, store.Store) {
	t.Helper()
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	return srv, st
}

// TestTrustReuseSeedFromStore proves SeedTrustReuseCache repopulates the in-memory
// cache from persisted rows at startup (survives a coordinator restart/deploy).
func TestTrustReuseSeedFromStore(t *testing.T) {
	srv, st := trustReuseServer(t)
	now := time.Now()
	if err := st.UpsertProviderTrustReuse(context.Background(), hardwareReuseRecord("se-x", "SER-X", trHashA, now)); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	srv.SeedTrustReuseCache(context.Background())
	if _, ok := srv.trustReuseCache.reuseTrust("se-x", "SER-X", trHashA); !ok {
		t.Fatal("seeded record must be reusable after SeedTrustReuseCache")
	}
}

// TestRecordTrustReusePersists proves the write-through reaches the store, so a
// simulated restart (fresh cache seeded from the store) can fast-skip.
func TestRecordTrustReusePersists(t *testing.T) {
	srv, st := trustReuseServer(t)
	srv.SeedTrustReuseCache(context.Background()) // wires the store (empty seed)

	srv.recordTrustReuse("se-y", "SER-Y", trHashA, true, true, "UDID-Y")

	// Write-through is async (saferun.Go); poll the store.
	if !waitForCond(2*time.Second, func() bool {
		rows, _ := st.ListProviderTrustReuse(context.Background())
		return len(rows) == 1 && rows[0].SEPubKey == "se-y" && rows[0].BinaryHash == trHashA
	}) {
		t.Fatal("recordTrustReuse must persist the record to the store")
	}

	// A record with no usable binary hash is NOT cached (read gate requires a match).
	srv.recordTrustReuse("se-nohash", "SER-N", "not-a-hash", true, true, "UDID-N")
	if _, ok := srv.trustReuseCache.reuseTrust("se-nohash", "SER-N", trHashA); ok {
		t.Fatal("a record with an unusable binary hash must not be cached/reusable")
	}
}

// TestInvalidateTrustReuseDeletesPersisted proves the hard-untrust invalidation
// removes the record both in-memory and from the store SYNCHRONOUSLY (FIX 1: the
// persisted delete is inline now, not fire-and-forget), and that wiring the
// registry hook fires it on a real hard untrust.
func TestInvalidateTrustReuseDeletesPersisted(t *testing.T) {
	srv, st := trustReuseServer(t)
	srv.SeedTrustReuseCache(context.Background()) // wires store + hard-untrust hook

	srv.trustReuseCache.recordTrust(hardwareReuseRecord("se-z", "SER-Z", trHashA, time.Now()))
	if err := st.UpsertProviderTrustReuse(context.Background(), hardwareReuseRecord("se-z", "SER-Z", trHashA, time.Now())); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	srv.invalidateTrustReuse("se-z")

	if _, ok := srv.trustReuseCache.reuseTrust("se-z", "SER-Z", trHashA); ok {
		t.Fatal("invalidate must drop the in-memory record")
	}
	// Inline delete → row gone as soon as invalidateTrustReuse returns (no polling).
	if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("invalidate must delete the persisted record synchronously, got %d rows", len(rows))
	}

	// The registry hard-untrust hook must invalidate on a real hard untrust. The
	// hook fires synchronously off all registry locks, and the in-memory + inline
	// persisted delete are both synchronous, so no polling is needed.
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", PublicKey: testPublicKeyB64(),
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	}
	p := srv.registry.Register("prov-hook", nil, msg)
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "SER-H", PublicKey: "se-hook"}
	p.Mu().Unlock()
	srv.trustReuseCache.recordTrust(hardwareReuseRecord("se-hook", "SER-H", trHashA, time.Now()))

	srv.registry.MarkUntrusted("prov-hook") // hard untrust → hook fires

	if srv.trustReuseCache.hasFreshRecord("se-hook", "SER-H") {
		t.Fatal("a hard untrust must invalidate the device's trust-reuse record (durable hard-untrust)")
	}
}

// TestInvalidateTrustReuseRetriesPersistedDelete proves FIX 1's bounded inline
// retry: a transient store-delete failure is retried, and the persisted row is
// ultimately removed (so a restart cannot reseed it).
func TestInvalidateTrustReuseRetriesPersistedDelete(t *testing.T) {
	old := trustReuseDeleteRetryBackoff
	trustReuseDeleteRetryBackoff = time.Millisecond // keep the test fast
	defer func() { trustReuseDeleteRetryBackoff = old }()

	srv, _ := trustReuseServer(t)
	mem := store.NewMemory(store.Config{})
	flaky := &flakyDeleteStore{Store: mem, failFirst: 2} // fail twice, succeed on the 3rd
	srv.trustReuseCache.store = flaky

	rec := hardwareReuseRecord("se-retry", "SER-RT", trHashA, time.Now())
	srv.trustReuseCache.recordTrust(rec)
	if err := mem.UpsertProviderTrustReuse(context.Background(), rec); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	srv.invalidateTrustReuse("se-retry")

	if srv.trustReuseCache.hasFreshRecord("se-retry", "SER-RT") {
		t.Fatal("in-memory record must be dropped synchronously")
	}
	if got := flaky.calls(); got != 3 {
		t.Fatalf("delete attempts = %d, want 3 (2 failures then success)", got)
	}
	if rows, _ := mem.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("persisted row must be deleted after retries, got %d rows", len(rows))
	}
}

// TestInvalidateTrustReuseDurableAcrossRestart proves FIX 1's durability goal: a
// hard untrust (via the registry hook) deletes the persisted row, so a simulated
// restart that seeds a FRESH cache from the SAME store finds nothing — the
// device cannot fast-skip after a restart on a stale, pre-untrust record.
func TestInvalidateTrustReuseDurableAcrossRestart(t *testing.T) {
	srv, st := trustReuseServer(t)
	srv.SeedTrustReuseCache(context.Background()) // wires store + hook

	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", PublicKey: testPublicKeyB64(),
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	}
	p := srv.registry.Register("prov-dur", nil, msg)
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "SER-DUR", PublicKey: "se-dur"}
	p.Mu().Unlock()

	srv.recordTrustReuse("se-dur", "SER-DUR", trHashA, true, true, "udid-dur")
	// recordTrustReuse persists via saferun.Go — wait for it before untrusting so
	// the delete cannot race ahead of the write-through.
	if !waitForCond(2*time.Second, func() bool {
		rows, _ := st.ListProviderTrustReuse(context.Background())
		return len(rows) == 1
	}) {
		t.Fatal("precondition: record must be persisted")
	}

	srv.registry.MarkUntrusted("prov-dur") // hard untrust → hook → synchronous persisted delete

	// "Restart": a FRESH cache seeded from the SAME store must find nothing.
	fresh := newTrustReuseCache()
	rows, err := st.ListProviderTrustReuse(context.Background())
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if n := fresh.seed(rows); n != 0 {
		t.Fatalf("seeded %d records after a hard untrust; want 0 (durable invalidation)", n)
	}
	if fresh.hasFreshRecord("se-dur", "SER-DUR") {
		t.Fatal("a hard-untrusted device must not be reusable after a restart reseed")
	}
}

// --- Read-path fast-skip gate tests (tryTrustReuseFastSkip) ---

// trustReuseFastSkipProvider builds a server + self_signed provider with a valid
// registration-bound attestation (serial + SE key + binary hash), and a fake clock
// on the cache so freshness is deterministic.
func trustReuseFastSkipProvider(t *testing.T) (*Server, *registry.Provider, *func() time.Time) {
	t.Helper()
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	cur := time.Unix(1_700_000_000, 0)
	clock := func() time.Time { return cur }
	srv.trustReuseCache.now = clock

	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", PublicKey: testPublicKeyB64(),
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	}
	p := srv.registry.Register("prov-fs", nil, msg)
	p.Mu().Lock()
	p.TrustLevel = registry.TrustSelfSigned
	p.AttestationResult = &attestation.VerificationResult{
		Valid: true, SerialNumber: "SERIAL-1", SIPEnabled: true, SecureBootEnabled: true,
		PublicKey: "se-pub-key-bytes", BinaryHash: trHashA,
	}
	p.Mu().Unlock()
	return srv, p, &clock
}

// goodFastSkipResp is a fresh SIGNED challenge response that satisfies the
// posture + binary gates for the device built by trustReuseFastSkipProvider.
func goodFastSkipResp() *protocol.AttestationResponseMessage {
	return &protocol.AttestationResponseMessage{
		SIPEnabled:        trBoolPtr(true),
		SecureBootEnabled: trBoolPtr(true),
		BinaryHash:        trHashA,
	}
}

// TestTrustReuseFastSkipGrantsOnAllGates: all gates pass → hardware granted, MDM
// round-trip skipped (the loop returns on hardware).
func TestTrustReuseFastSkipGrantsOnAllGates(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	srv.trustReuseCache.recordTrust(hardwareReuseRecord("se-pub-key-bytes", "SERIAL-1", trHashA, srv.trustReuseCache.now()))

	if !srv.tryTrustReuseFastSkip("prov-fs", p, goodFastSkipResp(), true /*statusFieldsTrusted*/) {
		t.Fatal("all gates pass → fast-skip must grant")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("trust = %q, want hardware after fast-skip grant", lvl)
	}
}

// TestTrustReuseFastSkipFallsThrough enumerates every gate miss; each must return
// false and leave the provider at self_signed (fall through to the unchanged full
// live MDM verify). Mirrors the spec's required fall-through cases.
func TestTrustReuseFastSkipFallsThrough(t *testing.T) {
	cases := []struct {
		name        string
		seedRecord  bool
		statusTrust bool
		mutate      func(p *registry.Provider, resp *protocol.AttestationResponseMessage, clock *func() time.Time, c *trustReuseCache)
	}{
		{
			name:        "no record",
			seedRecord:  false,
			statusTrust: true,
		},
		{
			name:        "binary hash changed",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(_ *registry.Provider, resp *protocol.AttestationResponseMessage, _ *func() time.Time, _ *trustReuseCache) {
				resp.BinaryHash = trHashB // differs from the cached/attested hash
			},
		},
		{
			name:        "serial mismatch",
			seedRecord:  false, // custom seed below
			statusTrust: true,
			mutate: func(_ *registry.Provider, _ *protocol.AttestationResponseMessage, _ *func() time.Time, c *trustReuseCache) {
				// Record keyed by the right SE key but a DIFFERENT serial than the
				// attestation ("SERIAL-1") → identity gate (a) fails.
				c.recordTrust(hardwareReuseRecord("se-pub-key-bytes", "SERIAL-2", trHashA, c.now()))
			},
		},
		{
			name:        "SE key mismatch",
			seedRecord:  false, // custom seed below
			statusTrust: true,
			mutate: func(_ *registry.Provider, _ *protocol.AttestationResponseMessage, _ *func() time.Time, c *trustReuseCache) {
				// Record under a DIFFERENT SE key than the attestation's
				// ("se-pub-key-bytes") → lookup finds nothing → falls through.
				c.recordTrust(hardwareReuseRecord("other-se-key", "SERIAL-1", trHashA, c.now()))
			},
		},
		{
			name:        "status fields not signed",
			seedRecord:  true,
			statusTrust: false, // statusFieldsTrusted=false → posture advisory, never trusted
		},
		{
			name:        "SIP not enabled in fresh challenge",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(_ *registry.Provider, resp *protocol.AttestationResponseMessage, _ *func() time.Time, _ *trustReuseCache) {
				resp.SIPEnabled = trBoolPtr(false)
			},
		},
		{
			name:        "Secure Boot not enabled in fresh challenge",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(_ *registry.Provider, resp *protocol.AttestationResponseMessage, _ *func() time.Time, _ *trustReuseCache) {
				resp.SecureBootEnabled = trBoolPtr(false)
			},
		},
		{
			name:        "Secure Boot omitted in fresh challenge",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(_ *registry.Provider, resp *protocol.AttestationResponseMessage, _ *func() time.Time, _ *trustReuseCache) {
				resp.SecureBootEnabled = nil
			},
		},
		{
			name:        "freshness window elapsed",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(_ *registry.Provider, _ *protocol.AttestationResponseMessage, clock *func() time.Time, c *trustReuseCache) {
				base := (*clock)()
				*clock = func() time.Time { return base.Add(c.reuseWindow + time.Minute) }
				c.now = *clock
			},
		},
		{
			name:        "provider hard-untrusted",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(p *registry.Provider, _ *protocol.AttestationResponseMessage, _ *func() time.Time, _ *trustReuseCache) {
				// Hard untrust (no hook wired in this harness, so the record stays —
				// the (e) gate alone must block the skip).
				// providerID is "prov-fs".
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, p, clock := trustReuseFastSkipProvider(t)
			if tc.seedRecord {
				srv.trustReuseCache.recordTrust(hardwareReuseRecord("se-pub-key-bytes", "SERIAL-1", trHashA, srv.trustReuseCache.now()))
			}
			resp := goodFastSkipResp()
			if tc.name == "provider hard-untrusted" {
				srv.registry.MarkUntrusted("prov-fs")
			}
			if tc.mutate != nil {
				tc.mutate(p, resp, clock, srv.trustReuseCache)
			}

			if srv.tryTrustReuseFastSkip("prov-fs", p, resp, tc.statusTrust) {
				t.Fatalf("%s: fast-skip must NOT grant", tc.name)
			}
			// Hard-untrust legitimately changes Status; in all other cases the
			// provider must remain exactly self_signed (full MDM still owes it).
			if tc.name != "provider hard-untrusted" {
				if lvl := p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
					t.Fatalf("%s: trust = %q, want self_signed (must fall through to full MDM)", tc.name, lvl)
				}
			}
		})
	}
}

// --- FIX 3: awaitTrustReuseGrant fast-path on the challenge-settled signal ---

// TestAwaitTrustReuseGrantReturnsOnSettledSignal proves FIX 3: when the live
// challenge settles WITHOUT a fast-skip grant, the settled signal makes
// awaitTrustReuseGrant return promptly (false) instead of stalling the full
// trustReuseGrantWait — so a non-fast-skip candidate proceeds to the full live MDM
// verify without an up-to-10s delay.
func TestAwaitTrustReuseGrantReturnsOnSettledSignal(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)

	// Mimic verifyChallengeResponse firing the signal after the fast-skip declined.
	p.SignalChallengeSettled()

	start := time.Now()
	if srv.awaitTrustReuseGrant(context.Background(), p) {
		t.Fatal("awaitTrustReuseGrant must return false when the challenge settled without a grant")
	}
	if elapsed := time.Since(start); elapsed >= trustReuseGrantWait {
		t.Fatalf("settled signal must return well under the wait; took %s (>= %s)", elapsed, trustReuseGrantWait)
	}
}

// TestAwaitTrustReuseGrantReturnsTrueOnHardware proves the success path: once the
// fast-skip (or ACME) grants hardware, awaitTrustReuseGrant returns true so the
// mdmVerificationLoop skips the live MDM round-trip.
func TestAwaitTrustReuseGrantReturnsTrueOnHardware(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	if !p.GrantHardwareIfNotUntrusted() {
		t.Fatal("precondition: grant should succeed")
	}
	if !srv.awaitTrustReuseGrant(context.Background(), p) {
		t.Fatal("awaitTrustReuseGrant must return true once hardware is granted")
	}
}

// --- FIX 5: hard-untrust hook is wired independent of store presence ---

// TestSeedTrustReuseCacheWiresHookWithoutStore proves FIX 5: SeedTrustReuseCache
// wires the hard-untrust invalidation hook even when no store is available for
// persistence/seeding, so a hard untrust still drops the in-memory record (under
// the memory-store fallback the in-memory cache must stay correct).
func TestSeedTrustReuseCacheWiresHookWithoutStore(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
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
	srv.trustReuseCache.recordTrust(hardwareReuseRecord("se-nostore", "SER-NS", trHashA, time.Now()))

	srv.registry.MarkUntrusted("prov-nostore") // hard untrust → hook must fire even w/o store

	if srv.trustReuseCache.hasFreshRecord("se-nostore", "SER-NS") {
		t.Fatal("hard untrust must invalidate the in-memory record even with no store wired (FIX 5 decoupling)")
	}
}
