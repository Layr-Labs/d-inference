package api

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// dummyMDMClient returns a non-nil *mdm.Client (no network at construction) so
// tryTrustReuseFastSkip's "MDM configured" gate (FIX C) is satisfied in unit tests
// that don't stand up a fake MicroMDM server.
func dummyMDMClient() *mdm.Client {
	return mdm.NewClient("http://127.0.0.1:1", "test", quietLogger())
}

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

// upsertHookStore wraps a real store and runs onUpsert just BEFORE delegating the
// reuse-record upsert. It deterministically injects a hard untrust into the
// check-then-write window (between recordTrustReuse's pre-write epoch check and the
// upsert committing) to exercise the FIX 2 post-write recheck.
type upsertHookStore struct {
	store.Store
	onUpsert func()
}

func (s *upsertHookStore) UpsertProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse) error {
	if s.onUpsert != nil {
		s.onUpsert()
	}
	return s.Store.UpsertProviderTrustReuse(ctx, rec)
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

// newTrustReuseProvider registers a fresh, online (not-untrusted, epoch 0) provider
// with the given SE key + serial, for exercising recordTrustReuse's epoch-checked
// write-through (FIX A) and the late-SecurityInfo path (FIX B).
func newTrustReuseProvider(t *testing.T, srv *Server, id, seKey, serial string) *registry.Provider {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", PublicKey: testPublicKeyB64(),
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	}
	p := srv.registry.Register(id, nil, msg)
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: serial, PublicKey: seKey}
	p.Mu().Unlock()
	return p
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

// TestRecordTrustReusePersists proves the write-through reaches the store
// SYNCHRONOUSLY (FIX A), so a simulated restart (fresh cache seeded from the store)
// can fast-skip.
func TestRecordTrustReusePersists(t *testing.T) {
	srv, st := trustReuseServer(t)
	srv.SeedTrustReuseCache(context.Background()) // wires the store (empty seed)
	p := newTrustReuseProvider(t, srv, "prov-y", "se-y", "SER-Y")

	srv.recordTrustReuse(p, "se-y", "SER-Y", trHashA, true, true, "UDID-Y")

	// Write-through is now synchronous — the row is present as soon as it returns.
	rows, _ := st.ListProviderTrustReuse(context.Background())
	if len(rows) != 1 || rows[0].SEPubKey != "se-y" || rows[0].BinaryHash != trHashA {
		t.Fatalf("recordTrustReuse must persist the record synchronously, got %+v", rows)
	}

	// A record with no usable binary hash is NOT cached (read gate requires a match).
	p2 := newTrustReuseProvider(t, srv, "prov-nohash", "se-nohash", "SER-N")
	srv.recordTrustReuse(p2, "se-nohash", "SER-N", "not-a-hash", true, true, "UDID-N")
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

	// Synchronous, epoch-checked write-through (FIX A): the row is persisted before
	// this returns.
	srv.recordTrustReuse(p, "se-dur", "SER-DUR", trHashA, true, true, "udid-dur")
	if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 1 {
		t.Fatalf("precondition: record must be persisted, got %d rows", len(rows))
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
	srv.mdmClient = dummyMDMClient() // satisfy the FIX C "MDM configured" gate
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

// --- FIX A: durable hard-untrust epoch (close the write-after-delete race) ---

// TestRecordTrustReuseSkipsPersistAfterHardUntrust proves FIX A ordering B: a hard
// untrust that has landed by the time recordTrustReuse does its pre-upsert recheck
// (epoch bumped + provider hard-untrusted) makes it persist NOTHING and keep no
// in-memory entry — so a synchronous write can never resurrect a row the untrust's
// synchronous delete already removed.
func TestRecordTrustReuseSkipsPersistAfterHardUntrust(t *testing.T) {
	srv, st := trustReuseServer(t)
	srv.SeedTrustReuseCache(context.Background())
	p := newTrustReuseProvider(t, srv, "prov-epoch", "se-epoch", "SER-EP")

	epochBefore := p.HardUntrustEpoch()
	srv.registry.MarkUntrusted("prov-epoch") // bumps the epoch + sets Status=Untrusted
	if p.HardUntrustEpoch() == epochBefore {
		t.Fatal("a hard untrust must bump the provider's hard-untrust epoch")
	}

	// The grant's write-through arrives AFTER the untrust — it must be refused.
	srv.recordTrustReuse(p, "se-epoch", "SER-EP", trHashA, true, true, "udid")

	if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("must NOT persist a record after a hard untrust, got %d rows", len(rows))
	}
	if srv.trustReuseCache.hasFreshRecord("se-epoch", "SER-EP") {
		t.Fatal("must NOT keep an in-memory record after a hard untrust")
	}
}

// TestRecordTrustReuseDurableBothOrderings proves FIX A's durability goal in both
// orderings: whether the hard untrust lands AFTER the record (ordering A: the
// untrust's synchronous delete removes the persisted row) or BEFORE the record
// completes (ordering B: the epoch recheck refuses to persist), a fresh cache
// seeded from the SAME store after a simulated restart finds no record.
func TestRecordTrustReuseDurableBothOrderings(t *testing.T) {
	seedFromStore := func(t *testing.T, st store.Store) int {
		t.Helper()
		rows, err := st.ListProviderTrustReuse(context.Background())
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		return newTrustReuseCache().seed(rows)
	}

	t.Run("ordering A: record then untrust", func(t *testing.T) {
		srv, st := trustReuseServer(t)
		srv.SeedTrustReuseCache(context.Background())
		p := newTrustReuseProvider(t, srv, "prov-a", "se-a", "SER-A")

		srv.recordTrustReuse(p, "se-a", "SER-A", trHashA, true, true, "udid")
		if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 1 {
			t.Fatalf("record must be persisted first, got %d rows", len(rows))
		}
		srv.registry.MarkUntrusted("prov-a") // hook → synchronous delete
		if n := seedFromStore(t, st); n != 0 {
			t.Fatalf("ordering A: restart reseed = %d, want 0", n)
		}
	})

	t.Run("ordering B: untrust then record", func(t *testing.T) {
		srv, st := trustReuseServer(t)
		srv.SeedTrustReuseCache(context.Background())
		p := newTrustReuseProvider(t, srv, "prov-b", "se-b", "SER-B")

		srv.registry.MarkUntrusted("prov-b") // epoch bumped + delete (no row yet)
		srv.recordTrustReuse(p, "se-b", "SER-B", trHashA, true, true, "udid")
		if n := seedFromStore(t, st); n != 0 {
			t.Fatalf("ordering B: restart reseed = %d, want 0", n)
		}
	})
}

// --- FIX B: late-SecurityInfo grants are cached too ---

// TestApplyLateSecurityInfoCachesReuse proves FIX B: a self_signed→hardware upgrade
// via a late SecurityInfo persists a trust-reuse record (same epoch-checked
// write-through as the synchronous MDM path) so it gets restart-survivable
// fast-skip.
func TestApplyLateSecurityInfoCachesReuse(t *testing.T) {
	fake := &fakeMDMServer{device: &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true}}
	srv, p := mdmReliabilityServer(t, fake)
	srv.SeedTrustReuseCache(context.Background()) // wire store + hook
	// Give the provider a usable signed binary hash so the reuse record can bind.
	p.Mu().Lock()
	p.AttestationResult.BinaryHash = trHashA
	p.Mu().Unlock()

	srv.ApplyLateSecurityInfo("UDID-1", &mdm.SecurityInfoResponse{
		SystemIntegrityProtectionEnabled: true,
		SecureBootLevel:                  "full",
	})

	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("late SecurityInfo must upgrade to hardware, got %q", lvl)
	}
	if _, ok := srv.trustReuseCache.reuseTrust("se-pub-key-bytes", "SERIAL-1", trHashA); !ok {
		t.Fatal("late SecurityInfo grant must cache a reusable trust-reuse record (FIX B)")
	}
	if rows, _ := srv.store.ListProviderTrustReuse(context.Background()); len(rows) != 1 {
		t.Fatalf("late grant must persist exactly one reuse row, got %d", len(rows))
	}
}

// --- FIX C: fast-skip requires a configured MDM client ---

// TestTrustReuseFastSkipRequiresMDMConfigured proves FIX C: with a valid fresh
// record and all other gates passing, a nil mdmClient (no-MDM / misconfigured
// deploy) makes the fast-skip decline so hardware is never granted from cache with
// no live MDM fallback.
func TestTrustReuseFastSkipRequiresMDMConfigured(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	srv.mdmClient = nil // no MDM configured
	srv.trustReuseCache.recordTrust(hardwareReuseRecord("se-pub-key-bytes", "SERIAL-1", trHashA, srv.trustReuseCache.now()))

	if srv.tryTrustReuseFastSkip("prov-fs", p, goodFastSkipResp(), true) {
		t.Fatal("fast-skip must NOT grant when no MDM client is configured (no live fallback)")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
		t.Fatalf("provider must stay self_signed, got %q", lvl)
	}
}

// --- Round 2 FIX 1: empty-seKey / empty-binaryHash guard ---

// TestRecordTrustReuseRejectsEmptyInputs proves FIX 1: recordTrustReuse is a hard
// no-op for an empty seKey or empty binaryHash — no in-memory entry, no persisted
// row (an empty-key row would poison the cache/store; an empty binary hash can
// never satisfy the read gate).
func TestRecordTrustReuseRejectsEmptyInputs(t *testing.T) {
	srv, st := trustReuseServer(t)
	srv.SeedTrustReuseCache(context.Background())
	p := newTrustReuseProvider(t, srv, "prov-empty", "se-empty", "SER-E")

	srv.recordTrustReuse(p, "", "SER-E", trHashA, true, true, "udid")    // empty seKey
	srv.recordTrustReuse(p, "se-empty", "SER-E", "", true, true, "udid") // empty binaryHash

	if srv.trustReuseCache.hasFreshRecord("se-empty", "SER-E") {
		t.Fatal("empty seKey/binaryHash must not record in-memory")
	}
	if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("empty seKey/binaryHash must not persist, got %d rows", len(rows))
	}
}

// TestApplyLateSecurityInfoSkipsWhenNoBinaryHash proves FIX 1's ApplyLateSecurityInfo
// guard: a late grant for a provider whose SE attestation carries no binary hash
// upgrades trust but caches NO reuse record (rather than a dead/unbindable row).
func TestApplyLateSecurityInfoSkipsWhenNoBinaryHash(t *testing.T) {
	fake := &fakeMDMServer{device: &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true}}
	srv, p := mdmReliabilityServer(t, fake)
	srv.SeedTrustReuseCache(context.Background())
	// mdmReliabilityServer leaves AttestationResult.BinaryHash empty.

	srv.ApplyLateSecurityInfo("UDID-1", &mdm.SecurityInfoResponse{
		SystemIntegrityProtectionEnabled: true,
		SecureBootLevel:                  "full",
	})

	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("late SecurityInfo must still upgrade to hardware, got %q", lvl)
	}
	if rows, _ := srv.store.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("no reuse record may be cached without a binary hash, got %d rows", len(rows))
	}
}

// --- Round 2 FIX 2: post-write epoch recheck (check-then-write TOCTOU) ---

// TestRecordTrustReusePostWriteRecheckDeletesOnRacedUntrust proves FIX 2: a hard
// untrust landing in the window between the pre-write epoch check and the upsert
// committing is caught by the POST-write recheck, which deletes the just-written
// row and drops the in-memory entry — so nothing reseeds on a restart.
func TestRecordTrustReusePostWriteRecheckDeletesOnRacedUntrust(t *testing.T) {
	srv, _ := trustReuseServer(t)
	mem := store.NewMemory(store.Config{})
	p := newTrustReuseProvider(t, srv, "prov-toctou", "se-tt", "SER-TT")

	// Inject the hard untrust exactly during the upsert (i.e. after the pre-write
	// check passed, before/at the write committing).
	hooked := &upsertHookStore{Store: mem, onUpsert: func() {
		srv.registry.MarkUntrusted("prov-toctou")
	}}
	srv.trustReuseCache.store = hooked

	srv.recordTrustReuse(p, "se-tt", "SER-TT", trHashA, true, true, "udid")

	// The post-write recheck must have deleted the row it wrote under the race.
	if rows, _ := mem.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("post-write recheck must delete the row written under a racing untrust, got %d rows", len(rows))
	}
	if srv.trustReuseCache.hasFreshRecord("se-tt", "SER-TT") {
		t.Fatal("post-write recheck must drop the in-memory entry")
	}
	// A fresh cache seeded from the same store (simulated restart) finds nothing.
	if n := newTrustReuseCache().seed(mustList(t, mem)); n != 0 {
		t.Fatalf("restart reseed = %d, want 0 (durable untrust)", n)
	}
}

func mustList(t *testing.T, st store.Store) []store.ProviderTrustReuse {
	t.Helper()
	rows, err := st.ListProviderTrustReuse(context.Background())
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	return rows
}

// --- Round 2 FIX 4a: reconcile ACME after a fast-skip grant ---

// TestReconcileACMEAfterFastSkipClearsUnboundFlag proves FIX 4a: when an MDM-reuse
// fast-skip grants hardware while a connect-time ACME cert is stashed but never
// bound (its SE-key binding can't complete), the unbound, unvalidated ACMEVerified
// flag is cleared and the stale pending result discarded — so the attestation
// report does not falsely claim acme_verified.
func TestReconcileACMEAfterFastSkipClearsUnboundFlag(t *testing.T) {
	srv, _ := trustReuseServer(t)
	p := newTrustReuseProvider(t, srv, "prov-acme", "se-acme", "SER-AC")
	// AttestationResult has no EncryptionPublicKey, so the ACME SE-key binding can
	// never complete on retry (providerHasBoundEncryptionAttestation is false).
	p.Mu().Lock()
	p.ACMEVerified = true // optimistically set by applyACMETrust before binding
	p.Mu().Unlock()
	s := srv
	s.stashPendingACME("prov-acme", &ACMEVerificationResult{Valid: true, SerialNumber: "SER-AC"})

	s.reconcileACMEAfterFastSkip("prov-acme", p)

	p.Mu().Lock()
	acme := p.ACMEVerified
	p.Mu().Unlock()
	if acme {
		t.Fatal("an unbound ACME result must not leave ACMEVerified=true after a fast-skip grant")
	}
	if s.hasPendingACME("prov-acme") {
		t.Fatal("the stale unbound pending ACME result must be discarded")
	}
}

// TestReconcileACMEAfterFastSkipNoPendingIsNoop proves reconcile is a no-op when no
// ACME was stashed (so a genuinely-bound-and-granted ACME flag is left intact).
func TestReconcileACMEAfterFastSkipNoPendingIsNoop(t *testing.T) {
	srv, _ := trustReuseServer(t)
	p := newTrustReuseProvider(t, srv, "prov-acme2", "se-acme2", "SER-AC2")
	p.Mu().Lock()
	p.ACMEVerified = true // simulate an already-bound+granted ACME
	p.Mu().Unlock()

	srv.reconcileACMEAfterFastSkip("prov-acme2", p)

	p.Mu().Lock()
	acme := p.ACMEVerified
	p.Mu().Unlock()
	if !acme {
		t.Fatal("reconcile must not clear ACMEVerified when nothing is stashed (already bound)")
	}
}

// --- Round 2 FIX 3 / FIX 4b: verifyChallengeResponse wiring (drain + ACME/signal) ---

// fastSkipChallengeResp builds a fully-signed challenge response (challenge sig +
// status sig so statusFieldsTrusted=true) that satisfies the fast-skip posture +
// binary gates for a provider registered with createTestAttestationJSONWithBinaryHash.
func fastSkipChallengeResp(t *testing.T, nonce, ts, pubKey, binHash string) *protocol.AttestationResponseMessage {
	t.Helper()
	sip, sb, rdma := true, true, true
	resp := &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             nonce,
		Signature:         testChallengeSignature(nonce, ts, pubKey),
		PublicKey:         pubKey,
		SIPEnabled:        &sip,
		SecureBootEnabled: &sb,
		RDMADisabled:      &rdma,
		BinaryHash:        binHash,
	}
	resp.StatusSignature = testStatusSignature(t, attestation.StatusCanonicalInput{
		Nonce: nonce, Timestamp: ts, RDMADisabled: &rdma,
		SIPEnabled: &sip, SecureBootEnabled: &sb, BinaryHash: binHash,
	}, pubKey)
	return resp
}

// TestVerifyChallengeFastSkipGrantDrainsQueue proves FIX 3: when the fast-skip
// grants hardware from the trust-reuse cache, verifyChallengeResponse drains the
// provider's queued work immediately (instead of waiting for a heartbeat / 120s
// timeout). Without the drain the queued request would not dispatch from the
// challenge path at all.
func TestVerifyChallengeFastSkipGrantDrainsQueue(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.mdmClient = dummyMDMClient()
	srv.SeedTrustReuseCache(context.Background())

	const model = "fast-skip-drain-model"
	binHash := trHashA
	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		DecodeTPS:               90,
		PrefillTPS:              900,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, binHash),
	}
	p := reg.Register("prov-drain", nil, regMsg)
	srv.verifyProviderAttestation("prov-drain", p, regMsg)

	// Test attestation blobs carry no serial; set one + make the provider routable.
	p.Mu().Lock()
	seKey := p.AttestationResult.PublicKey
	p.AttestationResult.SerialNumber = "SER-DRAIN"
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "running"}},
	}
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.Mu().Unlock()

	// Seed a fresh trust-reuse record so the fast-skip can grant.
	srv.trustReuseCache.recordTrust(hardwareReuseRecord(seKey, "SER-DRAIN", binHash, time.Now()))

	// Enqueue work for the model.
	req := &registry.QueuedRequest{
		RequestID:  "queued-fast-skip",
		Model:      model,
		ResponseCh: make(chan *registry.Provider, 1),
		Pending: &registry.PendingRequest{
			RequestID: "queued-fast-skip", Model: model,
			RequestedMaxTokens: 256, EstimatedPromptTokens: 50,
		},
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	nonce, ts := "nonce-fs", "2026-04-24T12:00:00Z"
	srv.verifyChallengeResponse("prov-drain", p, &pendingChallenge{nonce: nonce, timestamp: ts},
		fastSkipChallengeResp(t, nonce, ts, pubKey, binHash))

	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("fast-skip must grant hardware, got %q", lvl)
	}
	select {
	case assigned := <-req.ResponseCh:
		if assigned == nil || assigned.ID != "prov-drain" {
			t.Fatalf("expected drain dispatch to prov-drain, got %+v", assigned)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fast-skip grant must drain the queued request to the provider (FIX 3)")
	}
}

// TestVerifyChallengeFastSkipMissSignalsSettled proves FIX 4b: when the fast-skip
// MISSES (no reuse record) and ACME does not promote, verifyChallengeResponse fires
// the challenge-settled signal so the mdmVerificationLoop stops deferring and runs
// the full live MDM verify. The provider stays self_signed.
func TestVerifyChallengeFastSkipMissSignalsSettled(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.mdmClient = dummyMDMClient()
	srv.SeedTrustReuseCache(context.Background())

	binHash := trHashA
	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                protocol.TypeRegister,
		Hardware:            protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:              []protocol.ModelInfo{{ID: "fast-skip-miss-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:             registry.BackendMLXSwift,
		PublicKey:           pubKey,
		PrivacyCapabilities: testPrivacyCaps(),
		Attestation:         createTestAttestationJSONWithBinaryHash(t, pubKey, binHash),
	}
	p := reg.Register("prov-miss", nil, regMsg)
	srv.verifyProviderAttestation("prov-miss", p, regMsg)
	p.Mu().Lock()
	p.AttestationResult.SerialNumber = "SER-MISS"
	p.Mu().Unlock()

	// No trust-reuse record seeded → fast-skip misses. No pending ACME → no promotion.
	nonce, ts := "nonce-miss", "2026-04-24T12:00:00Z"
	srv.verifyChallengeResponse("prov-miss", p, &pendingChallenge{nonce: nonce, timestamp: ts},
		fastSkipChallengeResp(t, nonce, ts, pubKey, binHash))

	if lvl := p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
		t.Fatalf("no record + no ACME → provider must stay self_signed, got %q", lvl)
	}
	select {
	case <-p.ChallengeSettledChan():
		// good — settled signal fired so the MDM loop proceeds to live verify.
	default:
		t.Fatal("a fast-skip miss with no ACME promotion must fire the challenge-settled signal (FIX 4b)")
	}
}
