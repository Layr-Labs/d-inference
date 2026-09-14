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

// TestTrustReuseSeedFromStore proves SeedTrustReuseCache repopulates the in-memory
// cache from persisted rows at startup (survives a coordinator restart/deploy).
func TestTrustReuseSeedFromStore(t *testing.T) {
	srv, st := trustReuseServer(t)
	now := time.Now()
	if _, err := st.UpsertProviderTrustReuse(context.Background(), hardwareReuseRecord("se-x", "SER-X", trHashA, now), 0); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	srv.SeedTrustReuseCache(context.Background())
	if _, ok := srv.cache.reuse("se-x", "SER-X", trHashA); !ok {
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

	srv.RecordVerified(p, "se-y", "SER-Y", trHashA, true, true, "UDID-Y")

	// Write-through is now synchronous — the row is present as soon as it returns.
	rows, _ := st.ListProviderTrustReuse(context.Background())
	if len(rows) != 1 || rows[0].SEPubKey != "se-y" || rows[0].LastVerifiedBinaryHash != trHashA {
		t.Fatalf("recordTrustReuse must persist the record synchronously, got %+v", rows)
	}

	// A record with no usable binary hash is NOT cached (read gate requires a match).
	p2 := newTrustReuseProvider(t, srv, "prov-nohash", "se-nohash", "SER-N")
	srv.RecordVerified(p2, "se-nohash", "SER-N", "not-a-hash", true, true, "UDID-N")
	if _, ok := srv.cache.reuse("se-nohash", "SER-N", trHashA); ok {
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

	srv.cache.recordTrust(hardwareReuseRecord("se-z", "SER-Z", trHashA, time.Now()))
	if _, err := st.UpsertProviderTrustReuse(context.Background(), hardwareReuseRecord("se-z", "SER-Z", trHashA, time.Now()), 0); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	srv.Invalidate("se-z")

	if _, ok := srv.cache.reuse("se-z", "SER-Z", trHashA); ok {
		t.Fatal("invalidate must drop the in-memory record")
	}
	rows, _ := st.ListProviderTrustReuse(context.Background())
	if len(rows) != 1 || rows[0].RevokedAt == nil {
		t.Fatalf("invalidate must persist one revocation tombstone, got %+v", rows)
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
	srv.cache.recordTrust(hardwareReuseRecord("se-hook", "SER-H", trHashA, time.Now()))

	srv.registry.MarkUntrusted("prov-hook") // hard untrust → hook fires

	if srv.cache.hasFreshRecord("se-hook", "SER-H") {
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
	srv.cache.store = flaky

	rec := hardwareReuseRecord("se-retry", "SER-RT", trHashA, time.Now())
	srv.cache.recordTrust(rec)
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	srv.Invalidate("se-retry")

	if srv.cache.hasFreshRecord("se-retry", "SER-RT") {
		t.Fatal("in-memory record must be dropped synchronously")
	}
	if got := flaky.calls(); got != 3 {
		t.Fatalf("delete attempts = %d, want 3 (2 failures then success)", got)
	}
	if rows, _ := mem.ListProviderTrustReuse(context.Background()); len(rows) != 1 || rows[0].RevokedAt == nil {
		t.Fatalf("persisted row must be a tombstone after retries, got %+v", rows)
	}
}

func TestAmbiguousRevocationRetryIsIdempotent(t *testing.T) {
	old := trustReuseDeleteRetryBackoff
	trustReuseDeleteRetryBackoff = time.Millisecond
	defer func() { trustReuseDeleteRetryBackoff = old }()

	srv, _ := trustReuseServer(t)
	mem := store.NewMemory(store.Config{})
	ambiguous := &ambiguousRevokeStore{Store: mem}
	srv.cache.store = ambiguous
	rec := hardwareReuseRecord("se-ambiguous", "SER-A", trHashA, time.Now())
	srv.cache.recordTrust(rec)
	if _, err := mem.UpsertProviderTrustReuse(
		context.Background(), rec, 0); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	srv.Invalidate("se-ambiguous")
	rows, _ := mem.ListProviderTrustReuse(context.Background())
	if len(rows) != 1 || rows[0].RevokedAt == nil ||
		rows[0].RevocationGeneration != 1 ||
		rows[0].RevocationEventID == "" {
		t.Fatalf("ambiguous retry did not preserve one event/generation: %+v", rows)
	}
	cacheGeneration, cacheEventID := srv.cache.revocationState("se-ambiguous")
	if cacheGeneration != rows[0].RevocationGeneration ||
		cacheEventID != rows[0].RevocationEventID {
		t.Fatalf("cache did not install authoritative revocation: generation=%d event=%q row=%+v",
			cacheGeneration, cacheEventID, rows[0])
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
	srv.RecordVerified(p, "se-dur", "SER-DUR", trHashA, true, true, "udid-dur")
	if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 1 {
		t.Fatalf("precondition: record must be persisted, got %d rows", len(rows))
	}

	srv.registry.MarkUntrusted("prov-dur") // hard untrust → hook → synchronous persisted delete

	// "Restart": a FRESH cache seeded from the SAME store must find nothing.
	fresh := newCache()
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

// TestTrustReuseFastSkipGrantsOnAllGates: all gates pass → hardware granted, MDM
// round-trip skipped (the loop returns on hardware).
func TestTrustReuseFastSkipGrantsOnAllGates(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	srv.cache.recordTrust(hardwareReuseRecord("se-pub-key-bytes", "SERIAL-1", trHashA, srv.cache.now()))

	if !srv.TryReuse("prov-fs", p, goodFastSkipResp(), true /*statusFieldsTrusted*/) {
		t.Fatal("all gates pass → fast-skip must grant")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("trust = %q, want hardware after fast-skip grant", lvl)
	}
}

// TestTrustReuseFastSkipDurableCASBlocksStaleCoordinator proves a cache seed is
// never authoritative over a newer durable tombstone.
func TestTrustReuseFastSkipDurableCASBlocksStaleCoordinator(t *testing.T) {
	srv, p, _ := trustReuseFastSkipProvider(t)
	mem := srv.store.(*store.MemoryStore)
	rec := hardwareReuseRecord(
		"se-pub-key-bytes", "SERIAL-1", trHashA, srv.cache.now())
	srv.cache.recordTrust(rec)
	srv.cache.store = mem
	if _, err := mem.UpsertProviderTrustReuse(
		context.Background(), rec, 0); err != nil {
		t.Fatalf("seed durable evidence: %v", err)
	}
	if _, err := mem.RevokeProviderTrustReuse(
		context.Background(), rec.SEPubKey, "durable-revocation"); err != nil {
		t.Fatalf("durable revoke: %v", err)
	}

	if srv.TryReuse(
		"prov-fs", p, goodFastSkipResp(), true) {
		t.Fatal("stale coordinator cache granted across durable tombstone")
	}
	if got := p.GetTrustLevel(); got != registry.TrustSelfSigned {
		t.Fatalf("durable CAS failure left trust=%q, want self_signed", got)
	}
}

// TestTrustReuseFastSkipFallsThrough enumerates every gate miss; each must return
// false and leave the provider at self_signed for the full live MDM fallback.
func TestTrustReuseFastSkipFallsThrough(t *testing.T) {
	cases := []struct {
		name        string
		seedRecord  bool
		statusTrust bool
		mutate      func(p *registry.Provider, resp *protocol.AttestationResponseMessage, clock *func() time.Time, c *cache)
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
			mutate: func(_ *registry.Provider, resp *protocol.AttestationResponseMessage, _ *func() time.Time, _ *cache) {
				resp.BinaryHash = trHashB // differs from the cached/attested hash
			},
		},
		{
			name:        "serial mismatch",
			seedRecord:  false, // custom seed below
			statusTrust: true,
			mutate: func(_ *registry.Provider, _ *protocol.AttestationResponseMessage, _ *func() time.Time, c *cache) {
				// Record keyed by the right SE key but a DIFFERENT serial than the
				// attestation ("SERIAL-1") → identity gate (a) fails.
				c.recordTrust(hardwareReuseRecord("se-pub-key-bytes", "SERIAL-2", trHashA, c.now()))
			},
		},
		{
			name:        "SE key mismatch",
			seedRecord:  false, // custom seed below
			statusTrust: true,
			mutate: func(_ *registry.Provider, _ *protocol.AttestationResponseMessage, _ *func() time.Time, c *cache) {
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
			mutate: func(_ *registry.Provider, resp *protocol.AttestationResponseMessage, _ *func() time.Time, _ *cache) {
				resp.SIPEnabled = trBoolPtr(false)
			},
		},
		{
			name:        "Secure Boot not enabled in fresh challenge",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(_ *registry.Provider, resp *protocol.AttestationResponseMessage, _ *func() time.Time, _ *cache) {
				resp.SecureBootEnabled = trBoolPtr(false)
			},
		},
		{
			name:        "Secure Boot omitted in fresh challenge",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(_ *registry.Provider, resp *protocol.AttestationResponseMessage, _ *func() time.Time, _ *cache) {
				resp.SecureBootEnabled = nil
			},
		},
		{
			name:        "freshness window elapsed",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(_ *registry.Provider, _ *protocol.AttestationResponseMessage, clock *func() time.Time, c *cache) {
				base := (*clock)()
				*clock = func() time.Time { return base.Add(c.reuseWindow + time.Minute) }
				c.now = *clock
			},
		},
		{
			name:        "provider hard-untrusted",
			seedRecord:  true,
			statusTrust: true,
			mutate: func(p *registry.Provider, _ *protocol.AttestationResponseMessage, _ *func() time.Time, _ *cache) {
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
				srv.cache.recordTrust(hardwareReuseRecord("se-pub-key-bytes", "SERIAL-1", trHashA, srv.cache.now()))
			}
			resp := goodFastSkipResp()
			if tc.name == "provider hard-untrusted" {
				srv.registry.MarkUntrusted("prov-fs")
			}
			if tc.mutate != nil {
				tc.mutate(p, resp, clock, srv.cache)
			}

			if srv.TryReuse("prov-fs", p, resp, tc.statusTrust) {
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
	srv.RecordVerified(p, "se-epoch", "SER-EP", trHashA, true, true, "udid")

	if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 1 || rows[0].RevokedAt == nil {
		t.Fatalf("hard untrust must leave exactly one tombstone, got %+v", rows)
	}
	if srv.cache.hasFreshRecord("se-epoch", "SER-EP") {
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
		return newCache().seed(rows)
	}

	t.Run("ordering A: record then untrust", func(t *testing.T) {
		srv, st := trustReuseServer(t)
		srv.SeedTrustReuseCache(context.Background())
		p := newTrustReuseProvider(t, srv, "prov-a", "se-a", "SER-A")

		srv.RecordVerified(p, "se-a", "SER-A", trHashA, true, true, "udid")
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
		srv.RecordVerified(p, "se-b", "SER-B", trHashA, true, true, "udid")
		if n := seedFromStore(t, st); n != 0 {
			t.Fatalf("ordering B: restart reseed = %d, want 0", n)
		}
	})
}

// TestRecordTrustReuseRejectsEmptyIdentity: recordTrustReuse is a hard no-op
// for an empty seKey (an empty-key row would poison the cache/store). An empty
// BINARY hash is different — it is an optional self-report; see
// TestRecordTrustReuseGrantsDeviceTrustWithoutBinaryHash.
func TestRecordTrustReuseRejectsEmptyIdentity(t *testing.T) {
	srv, st := trustReuseServer(t)
	srv.SeedTrustReuseCache(context.Background())
	p := newTrustReuseProvider(t, srv, "prov-empty", "se-empty", "SER-E")

	if srv.RecordVerified(p, "", "SER-E", trHashA, true, true, "udid") {
		t.Fatal("empty seKey must not grant")
	}
	if srv.RecordVerified(p, "se-empty", "", trHashA, true, true, "udid") {
		t.Fatal("empty serial must not grant")
	}
	if srv.cache.hasFreshRecord("se-empty", "SER-E") {
		t.Fatal("empty identity must not record in-memory")
	}
	if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("empty identity must not persist, got %d rows", len(rows))
	}
}

// TestRecordTrustReuseGrantsDeviceTrustWithoutBinaryHash is the review
// finding-2 regression: the self-reported application binary hash is OPTIONAL,
// and a provider omitting it has still fully proven its DEVICE (SE identity +
// live MDM posture). The synchronous full-verification path must grant
// hardware trust — while remaining fail-closed on the reuse side: no
// unbindable (hashless) reuse row is persisted or cached, so every reconnect
// re-runs the full live verification.
func TestRecordTrustReuseGrantsDeviceTrustWithoutBinaryHash(t *testing.T) {
	srv, st := trustReuseServer(t)
	srv.SeedTrustReuseCache(context.Background())
	p := newTrustReuseProvider(t, srv, "prov-hashless", "se-hashless", "SER-H")

	if !srv.RecordVerified(p, "se-hashless", "SER-H", "", true, true, "udid-h") {
		t.Fatal("omitting the optional binary hash must not block device trust")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("hashless full verification granted %q, want hardware", lvl)
	}
	if srv.cache.hasFreshRecord("se-hashless", "SER-H") {
		t.Fatal("hashless grant must not cache an unbindable reuse record")
	}
	if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("hashless grant must not persist reuse rows, got %d", len(rows))
	}
	// An INVALID (non-empty) self-report is still refused outright.
	p2 := newTrustReuseProvider(t, srv, "prov-badhash", "se-badhash", "SER-B")
	if srv.RecordVerified(p2, "se-badhash", "SER-B", "not-a-hash", true, true, "udid-b") {
		t.Fatal("an invalid non-empty binary hash must not grant")
	}
}

// TestRecordLateTrustReuseWithoutBinaryHashRespectsTombstone: the late path has
// no revocation-recovery authority — a tombstoned identity stays untrusted even
// when the (hashless) grant would bypass the store CAS. The synchronous
// full-verification path retains its recovery authority for the live grant.
func TestRecordLateTrustReuseWithoutBinaryHashRespectsTombstone(t *testing.T) {
	srv, st := trustReuseServer(t)
	srv.SeedTrustReuseCache(context.Background())
	p := newTrustReuseProvider(t, srv, "prov-ts", "se-ts", "SER-T")
	srv.cache.invalidateReuse("se-ts", "tombstone-event")

	if srv.RecordLate(p, "se-ts", "SER-T", "", true, true, "udid-t") {
		t.Fatal("late hashless grant must refuse a tombstoned identity")
	}
	if lvl := p.GetTrustLevel(); lvl == registry.TrustHardware {
		t.Fatal("tombstoned identity gained hardware trust via the late path")
	}
	if !srv.RecordVerified(p, "se-ts", "SER-T", "", true, true, "udid-t") {
		t.Fatal("synchronous full verification retains live recovery authority")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Fatalf("post-recovery trust = %q, want hardware", lvl)
	}
	if rows, _ := st.ListProviderTrustReuse(context.Background()); len(rows) != 0 {
		t.Fatalf("hashless paths must never persist reuse rows, got %d", len(rows))
	}
}

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
	srv.cache.store = hooked

	srv.RecordVerified(p, "se-tt", "SER-TT", trHashA, true, true, "udid")

	// The post-write recheck must preserve the raced hard-untrust tombstone.
	if rows, _ := mem.ListProviderTrustReuse(context.Background()); len(rows) != 1 || rows[0].RevokedAt == nil {
		t.Fatalf("raced untrust must leave one tombstone, got %+v", rows)
	}
	if srv.cache.hasFreshRecord("se-tt", "SER-TT") {
		t.Fatal("post-write recheck must drop the in-memory entry")
	}
	// A fresh cache seeded from the same store (simulated restart) finds nothing.
	if n := newCache().seed(mustList(t, mem)); n != 0 {
		t.Fatalf("restart reseed = %d, want 0 (durable untrust)", n)
	}
}

// TestApprovedTransitionAdvancesDurableBinaryIdentity: after an approved A→B
// release transition granted hardware via reuse, the cached AND durable
// application identity must read B — with the ORIGINAL hardware-proof
// timestamp (binary churn must not extend the device-proof window). Otherwise,
// once release A is deactivated (ApprovedFromBinaryHashes only lists ACTIVE
// predecessors), the next B reconnect matches neither the same-binary nor the
// transition path and the fleet falls back to live MDM — including on a fresh
// coordinator seeded from the store during a blue-green deploy.
func TestApprovedTransitionAdvancesDurableBinaryIdentity(t *testing.T) {
	srv, provider, clock := trustReuseFastSkipProvider(t)
	mem := srv.store.(*store.MemoryStore)
	srv.cache.store = mem

	proofAt := (*clock)()
	rec := hardwareReuseRecord("se-pub-key-bytes", "SERIAL-1", trHashA, proofAt)
	srv.cache.recordTrust(rec)
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("seed durable evidence: %v", err)
	}

	evidenceAt := proofAt.Add(30 * time.Minute)
	provider.Mu().Lock()
	provider.ApplicationEvidence = registry.ApplicationEvidence{
		SEPublicKey: "se-pub-key-bytes", Serial: "SERIAL-1",
		ProcessPublicKey: "proc-key",
		BinaryHash:       trHashB,
		Version:          "0.9.0", Platform: "macos-arm64", Backend: "mlx-swift",
		VerifiedAt:         evidenceAt,
		EvidenceGeneration: 1,
		PolicyGeneration:   1,
	}
	provider.Mu().Unlock()

	resp := goodFastSkipResp()
	resp.BinaryHash = trHashB
	fact := ReleaseTransition{
		Approved: true, BinaryHash: trHashB, Version: "0.9.0",
		Platform: "macos-arm64", Backend: "mlx-swift", PolicyGeneration: 1,
		ApprovedFromBinaryHashes: map[string]struct{}{trHashA: {}},
	}
	if !srv.TryReuse("prov-fs", provider, resp, true, fact) {
		t.Fatal("approved A→B transition should grant from fresh device evidence")
	}

	rows := mustList(t, mem)
	if len(rows) != 1 || rows[0].LastVerifiedBinaryHash != trHashB {
		t.Fatalf("durable identity must advance to B, got %+v", rows)
	}
	if !rows[0].HardwareProofVerifiedAt.Equal(proofAt) {
		t.Fatalf("hardware-proof timestamp must not be refreshed by a binary transition: got %v, want %v",
			rows[0].HardwareProofVerifiedAt, proofAt)
	}
	if rows[0].ApplicationProofVerifiedAt == nil ||
		!rows[0].ApplicationProofVerifiedAt.Equal(evidenceAt) {
		t.Fatalf("application-proof timestamp must reflect the fresh B proof, got %v",
			rows[0].ApplicationProofVerifiedAt)
	}

	// Release A deactivated: no fact lists A as an approved predecessor
	// anymore. A B reconnect must reuse via the same-binary path — no fact,
	// no live MDM.
	result := srv.cache.decide(Input{
		SEPubKey: "se-pub-key-bytes", Serial: "SERIAL-1", FreshBinaryHash: trHashB,
	})
	if result.Decision != DecisionSameBinary {
		t.Fatalf("post-transition decision = %q (reason %q), want same_binary",
			result.Decision, result.Reason)
	}

	// Blue-green deploy: a fresh coordinator seeded from the SAME store must
	// reuse on B and refuse the retired A.
	restarted := newCacheWithWindow(defaultTrustReuseWindow)
	restarted.now = *clock
	restarted.seed(rows)
	if _, ok := restarted.reuse("se-pub-key-bytes", "SERIAL-1", trHashB); !ok {
		t.Fatal("restart-seeded cache must reuse on B after A is deactivated")
	}
	if _, ok := restarted.reuse("se-pub-key-bytes", "SERIAL-1", trHashA); ok {
		t.Fatal("retired A hash must no longer reuse after the identity advanced")
	}
}

// TestSeedRetainsExpiredRowGenerationForRecoveryCAS (Codex P1): an EXPIRED
// durable row for a previously-revoked-then-recovered device must be seeded as
// non-reusable generation state. Discarding it (old behavior) made the next
// full live MDM grant submit expected revocation generation zero, lose the
// recovery CAS against the durable row (generation 1), and be misclassified
// as a transient failure — a 2-4 minute retry, past the 120s queue deadline.
func TestSeedRetainsExpiredRowGenerationForRecoveryCAS(t *testing.T) {
	srv, st := trustReuseServer(t)
	t.Cleanup(srv.Close)
	ctx := context.Background()

	// Durable history: hard untrust (generation 1), then a reviewed full
	// recovery at that generation; the hardware proof then EXPIRES before the
	// coordinator restarts.
	if _, err := st.RevokeProviderTrustReuse(ctx, "se-gen", "evt-gen-1"); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	expired := hardwareReuseRecord("se-gen", "SER-GEN", trHashA, time.Now().Add(-2*time.Hour))
	if res, err := st.RecoverProviderTrustReuse(ctx, expired, 1); err != nil || !res.Applied {
		t.Fatalf("recover: applied=%v err=%v", res.Applied, err)
	}

	// Simulated restart: a fresh cache seeded from the store.
	if err := srv.SeedTrustReuseCache(ctx); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if srv.cache.hasFreshRecord("se-gen", "SER-GEN") {
		t.Fatal("an expired row must stay non-reusable after seeding")
	}
	if _, ok := srv.cache.reuse("se-gen", "SER-GEN", trHashA); ok {
		t.Fatal("an expired row must not admit reuse")
	}
	if gen, _ := srv.cache.revocationState("se-gen"); gen != 1 {
		t.Fatalf("seeded revocation generation = %d, want 1 (expired rows are retained CAS state)", gen)
	}

	// The next full live MDM grant must land at the durable generation — not
	// lose the recovery CAS and get classified transient.
	p := newTrustReuseProvider(t, srv, "prov-gen", "se-gen", "SER-GEN")
	if !srv.RecordVerified(p, "se-gen", "SER-GEN", trHashA, true, true, "udid-gen") {
		t.Fatal("full verification lost the recovery CAS against the durable generation")
	}
	rows, _ := st.ListProviderTrustReuse(ctx)
	if len(rows) != 1 || rows[0].RevokedAt != nil ||
		rows[0].RevocationGeneration != 1 ||
		rows[0].TrustLevel != string(registry.TrustHardware) {
		t.Fatalf("post-grant row = %+v, want live hardware at generation 1", rows)
	}
}
