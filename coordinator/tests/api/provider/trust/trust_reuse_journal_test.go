package trust_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/operations"
	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"

	trustjournal "github.com/eigeninference/d-inference/coordinator/internal/provider/journal"

	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/google/uuid"
)

type failingJournal struct {
	*trustjournal.File
	appendErr error
	removeErr error
}

func (j *failingJournal) Append(entry trustjournal.Entry) ([]trustjournal.Entry, error) {
	if j.appendErr != nil {
		return nil, j.appendErr
	}
	return j.File.Append(entry)
}

func (j *failingJournal) Remove(entry trustjournal.Entry) ([]trustjournal.Entry, error) {
	if j.removeErr != nil {
		return nil, j.removeErr
	}
	return j.File.Remove(entry)
}

type trustReuseListFailureStore struct {
	store.Store
}

func (s *trustReuseListFailureStore) ListProviderTrustReuse(context.Context) ([]store.ProviderTrustReuse, error) {
	return nil, errors.New("simulated trust-reuse list outage")
}

func durableTrustReuseTestServer(t *testing.T, st store.Store, journalPath string, journals ...trustjournal.Journal) *trustFixture {
	t.Helper()
	logger := quietLogger()
	var journal trustjournal.Journal
	if len(journals) > 0 {
		journal = journals[0]
	}
	return newTrustFixture(t, production.Dependencies{Registry: registry.New(logger), Store: st, Logger: logger, TrustReuseJournal: journal}, production.Config{
		DurableTrustReuse:     true,
		TrustReuseJournalPath: journalPath,
	})
}

func TestTrustAuthorityRejectsConcurrentCoordinator(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	st := memory.NewMemory(store.Config{})
	first := durableTrustReuseTestServer(t, st, path)
	if err := first.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("first coordinator authority: %v", err)
	}
	second := durableTrustReuseTestServer(t, st, path)
	if err := second.SeedTrustReuseCache(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "another coordinator owns") {
		t.Fatalf("concurrent coordinator authority error = %v", err)
	}
	first.Close()
	third := durableTrustReuseTestServer(t, st, path)
	defer third.Close()
	if err := third.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("authority did not transfer after close: %v", err)
	}
}

func TestHardUntrustJournalMalformedLineFailsClosed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	journal := trustjournal.NewFile(path)
	if err := journal.Initialize(); err != nil {
		t.Fatalf("Initialize: %v", err)
	}
	if err := os.WriteFile(path, []byte("{not-json}\n"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	srv := durableTrustReuseTestServer(t, memory.NewMemory(store.Config{}), path)
	if err := srv.SeedTrustReuseCache(context.Background()); err == nil {
		t.Fatal("malformed journal must fail startup seeding")
	}
	blocked, reason := srv.TrustSafetyStatus()
	if !blocked || reason != trustreuse.TrustSafetyJournalHealthReason {
		t.Fatalf("trust safety = blocked:%v reason:%q", blocked, reason)
	}
}

func TestHardUntrustJournalAppendFailureLatchesRoutingClosed(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	journal := &failingJournal{File: trustjournal.NewFile(path)}
	srv := durableTrustReuseTestServer(t, mem, path, journal)
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("SeedTrustReuseCache: %v", err)
	}
	journal.appendErr = errors.New("simulated fsync failure")
	rec := hardwareReuseRecord("se-append-fail", "SER-A", trHashA, time.Now())
	srv.trustReuseCache.RecordTrust(srv.trustReuseCache.PublicationGeneration(), rec)
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("UpsertProviderTrustReuse: %v", err)
	}

	srv.InvalidateTrustReuse(rec.SEPubKey)
	blocked, reason := srv.TrustSafetyStatus()
	if !blocked || reason != trustreuse.TrustSafetyJournalHealthReason {
		t.Fatalf("append failure latch = blocked:%v reason:%q", blocked, reason)
	}
	if _, ok := cachedTrust(srv.trustReuseCache, rec.SEPubKey, rec.Serial, trHashA); ok {
		t.Fatal("append failure retained reusable evidence")
	}
	ops := operations.New(operations.Dependencies{Drain: &operations.Drain{}, TrustSafety: srv.TrustSafetyStatus, Reject: srv.access.WriteTokenRateLimited})
	ready := httptest.NewRecorder()
	ops.HandleReadyz(ready, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if ready.Code != http.StatusServiceUnavailable ||
		!strings.Contains(ready.Body.String(), trustreuse.TrustSafetyJournalHealthReason) {
		t.Fatalf("readyz did not expose fixed trust-safety reason: status=%d body=%s",
			ready.Code, ready.Body.String())
	}
	routed := httptest.NewRecorder()
	ops.DrainGate(func(http.ResponseWriter, *http.Request) { t.Error("trust-safety latch reached inference") })(routed, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil))
	if routed.Code != http.StatusTooManyRequests {
		t.Fatalf("trust-safety latch allowed inference routing: status=%d body=%s",
			routed.Code, routed.Body.String())
	}
}

func TestHardUntrustJournalCleanupFailureLeavesPendingDenial(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	journal := &failingJournal{File: trustjournal.NewFile(path)}
	srv := durableTrustReuseTestServer(t, mem, path, journal)
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("SeedTrustReuseCache: %v", err)
	}
	journal.removeErr = errors.New("simulated rename failure")
	rec := hardwareReuseRecord("se-cleanup-fail", "SER-C", trHashA, time.Now())
	srv.trustReuseCache.RecordTrust(srv.trustReuseCache.PublicationGeneration(), rec)
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("UpsertProviderTrustReuse: %v", err)
	}

	srv.InvalidateTrustReuse(rec.SEPubKey)
	entries, err := srv.trustReuseJournal.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(entries) != 1 || entries[0].SEKeySHA256 != trustjournal.HashSEPublicKey(rec.SEPubKey) {
		t.Fatalf("cleanup failure did not retain exact entry: %+v", entries)
	}
	if !srv.DeniesIdentity(rec.SEPubKey) {
		t.Fatal("cleanup failure identity is not denied")
	}
	rows, _ := mem.ListProviderTrustReuse(context.Background())
	if len(rows) != 1 || rows[0].RevokedAt == nil {
		t.Fatalf("authoritative tombstone missing after cleanup failure: %+v", rows)
	}
}

func TestHardUntrustJournalStoreOutageKeepsPendingAndBlocksReplay(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	journal := trustjournal.NewFile(path)
	if err := journal.Initialize(); err != nil {
		t.Fatalf("Initialize: %v", err)
	}
	entry := trustjournal.NewEntry("se-store-outage", uuid.NewString())
	if _, err := journal.Append(entry); err != nil {
		t.Fatalf("Append: %v", err)
	}

	srv := durableTrustReuseTestServer(t, &trustReuseListFailureStore{Store: mem}, path)
	if err := srv.SeedTrustReuseCache(context.Background()); err == nil {
		t.Fatal("pending revocation plus store outage must fail startup replay")
	}
	blocked, reason := srv.TrustSafetyStatus()
	if !blocked || reason != trustreuse.TrustSafetyReplayHealthReason {
		t.Fatalf("replay outage safety = blocked:%v reason:%q", blocked, reason)
	}
	remaining, err := journal.Load()
	if err != nil || len(remaining) != 1 || remaining[0] != entry {
		t.Fatalf("store outage consumed pending journal entry: %+v, err=%v", remaining, err)
	}
	if !srv.DeniesIdentity("se-store-outage") {
		t.Fatal("store outage did not retain identity-level fast-skip denial")
	}
}

func TestHardUntrustJournalReviewerTraceThreeFailuresRestartRecovery(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	flaky := &flakyDeleteStore{Store: mem, failFirst: 3}
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	rec := hardwareReuseRecord("se-reviewer-trace", "SER-R", trHashA, time.Now())
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	beforeRestart := durableTrustReuseTestServer(t, flaky, path)
	if err := beforeRestart.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("initial SeedTrustReuseCache: %v", err)
	}
	beforeRestart.InvalidateTrustReuse(rec.SEPubKey)
	if got := flaky.calls(); got != 3 {
		t.Fatalf("initial DB revoke attempts = %d, want exactly 3", got)
	}
	entries, err := beforeRestart.trustReuseJournal.Load()
	if err != nil || len(entries) != 1 {
		t.Fatalf("pending journal after outage = %+v, err=%v", entries, err)
	}
	staleRows, _ := mem.ListProviderTrustReuse(context.Background())
	if len(staleRows) != 1 || staleRows[0].RevokedAt != nil {
		t.Fatalf("reviewer precondition requires stale unrevoked row: %+v", staleRows)
	}
	beforeRestart.Close()

	// Coordinator restart after DB recovery: the same local journal is loaded,
	// its stable event ID is replayed, and the stale row is excluded before seed.
	afterRestart := durableTrustReuseTestServer(t, flaky, path)
	defer afterRestart.Close()
	if err := afterRestart.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("restart SeedTrustReuseCache: %v", err)
	}
	if got := flaky.calls(); got != 4 {
		t.Fatalf("recovery DB revoke calls = %d, want one replay after the original three", got)
	}
	if afterRestart.trustReuseCache.HasFreshRecord(rec.SEPubKey, rec.Serial) {
		t.Fatal("stale pre-untrust row seeded after restart")
	}
	if _, ok := cachedTrust(afterRestart.trustReuseCache, rec.SEPubKey, rec.Serial, trHashA); ok {
		t.Fatal("stale pre-untrust row granted after restart")
	}
	recoveredRows, _ := mem.ListProviderTrustReuse(context.Background())
	if len(recoveredRows) != 1 || recoveredRows[0].RevokedAt == nil || recoveredRows[0].RevocationEventID != entries[0].RevocationID {
		t.Fatalf("replayed tombstone did not preserve event identity: %+v", recoveredRows)
	}
	remaining, err := afterRestart.trustReuseJournal.Load()
	if err != nil || len(remaining) != 0 {
		t.Fatalf("journal was not cleaned after authoritative replay: %+v, err=%v", remaining, err)
	}
}

func TestHardUntrustJournalRuntimeReplayClearsFailClosedLatch(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	flaky := &flakyDeleteStore{Store: mem, failFirst: 3}
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	rec := hardwareReuseRecord("se-runtime-replay", "SER-RUNTIME", trHashA, time.Now())
	if _, err := mem.UpsertProviderTrustReuse(
		context.Background(), rec, 0,
	); err != nil {
		t.Fatalf("seed store: %v", err)
	}
	srv := durableTrustReuseTestServer(t, flaky, path)
	defer srv.Close()
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("SeedTrustReuseCache: %v", err)
	}
	srv.InvalidateTrustReuse(rec.SEPubKey)
	if blocked, reason := srv.TrustSafetyStatus(); !blocked ||
		reason != trustreuse.TrustSafetyReplayHealthReason {
		t.Fatalf("runtime revoke failure did not fail closed: blocked=%v reason=%q", blocked, reason)
	}
	if !waitForCond(2*time.Second, func() bool {
		rows, err := mem.ListProviderTrustReuse(context.Background())
		if err != nil || len(rows) != 1 || rows[0].RevokedAt == nil {
			return false
		}
		entries, err := srv.trustReuseJournal.Load()
		if err != nil || len(entries) != 0 {
			return false
		}
		blocked, _ := srv.TrustSafetyStatus()
		return !blocked
	}) {
		t.Fatal("runtime revocation replay did not tombstone, clean journal, and restore readiness")
	}
}

// --- Codex P2: row-less hard untrust must converge on crash replay ---

// TestHardUntrustJournalReplayCreatesMissingTombstone: a hard untrust during a
// store outage for an SE identity with NO provider_trust_reuse row leaves a
// journal entry. Crash replay must not merely match listed rows — the entry
// carries the SE key, so replay creates the missing tombstone row, converges,
// and removes the entry (instead of denying the identity forever through the
// in-memory pending set alone).
func TestHardUntrustJournalReplayCreatesMissingTombstone(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	journal := trustjournal.NewFile(path)
	if err := journal.Initialize(); err != nil {
		t.Fatalf("Initialize: %v", err)
	}
	entry := trustjournal.NewEntry("se-no-row", uuid.NewString())
	if _, err := journal.Append(entry); err != nil {
		t.Fatalf("Append: %v", err)
	}

	srv := durableTrustReuseTestServer(t, mem, path)
	defer srv.Close()
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("SeedTrustReuseCache: %v", err)
	}

	rows, err := mem.ListProviderTrustReuse(context.Background())
	if err != nil || len(rows) != 1 || rows[0].SEPubKey != "se-no-row" ||
		rows[0].RevokedAt == nil || rows[0].RevocationEventID != entry.RevocationID {
		t.Fatalf("replay must create the missing tombstone row: %+v, err=%v", rows, err)
	}
	remaining, err := journal.Load()
	if err != nil || len(remaining) != 0 {
		t.Fatalf("converged entry must be removed from the journal: %+v, err=%v", remaining, err)
	}
	if srv.DeniesIdentity("se-no-row") {
		t.Fatal("converged identity must not stay in the pending denial set")
	}
	if blocked, reason := srv.TrustSafetyStatus(); blocked {
		t.Fatalf("converged replay must not block routing: reason=%q", reason)
	}
	if !srv.trustReuseCache.IsRevoked("se-no-row") {
		t.Fatal("replayed tombstone must be installed in the cache")
	}
}

// TestHardUntrustJournalLegacyDigestOnlyEntriesStillReplay: entries written
// before the SE key was embedded (digest-only) must keep loading and replaying
// against listed rows exactly as before — and a digest-only entry with no row
// must stay pending (fail closed) rather than being dropped.
func TestHardUntrustJournalLegacyDigestOnlyEntriesStillReplay(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	journal := trustjournal.NewFile(path)
	if err := journal.Initialize(); err != nil {
		t.Fatalf("Initialize: %v", err)
	}
	// Legacy on-disk shape: v1 without se_pub_key (omitempty reproduces the
	// exact old JSON).
	rowedLegacy := trustjournal.Entry{
		Version: 1,

		SEKeySHA256:  trustjournal.HashSEPublicKey("se-legacy-rowed"),
		RevocationID: uuid.NewString(),
	}
	rowlessLegacy := trustjournal.Entry{
		Version: 1,

		SEKeySHA256:  trustjournal.HashSEPublicKey("se-legacy-rowless"),
		RevocationID: uuid.NewString(),
	}
	if _, err := journal.Append(rowedLegacy); err != nil {
		t.Fatalf("Append rowed legacy: %v", err)
	}
	if _, err := journal.Append(rowlessLegacy); err != nil {
		t.Fatalf("Append rowless legacy: %v", err)
	}
	rec := hardwareReuseRecord("se-legacy-rowed", "SER-L", trHashA, time.Now())
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	srv := durableTrustReuseTestServer(t, mem, path)
	defer srv.Close()
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("SeedTrustReuseCache: %v", err)
	}

	rows, err := mem.ListProviderTrustReuse(context.Background())
	if err != nil || len(rows) != 1 || rows[0].SEPubKey != "se-legacy-rowed" ||
		rows[0].RevokedAt == nil || rows[0].RevocationEventID != rowedLegacy.RevocationID {
		t.Fatalf("legacy entry with a row must replay to a tombstone: %+v, err=%v", rows, err)
	}
	remaining, err := journal.Load()
	if err != nil || len(remaining) != 1 || remaining[0] != rowlessLegacy {
		t.Fatalf("row-less legacy entry must stay pending: %+v, err=%v", remaining, err)
	}
	if !srv.DeniesIdentity("se-legacy-rowless") {
		t.Fatal("row-less legacy identity must remain denied via the pending set")
	}
	if srv.DeniesIdentity("se-legacy-rowed") {
		t.Fatal("replayed legacy identity must leave the pending set")
	}
}
