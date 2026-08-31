package api

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

type failingJournal struct {
	hardUntrustJournal
	appendErr error
	removeErr error
}

func (j *failingJournal) Append(entry hardUntrustJournalEntry) ([]hardUntrustJournalEntry, error) {
	if j.appendErr != nil {
		return nil, j.appendErr
	}
	return j.hardUntrustJournal.Append(entry)
}

func (j *failingJournal) Remove(entry hardUntrustJournalEntry) ([]hardUntrustJournalEntry, error) {
	if j.removeErr != nil {
		return nil, j.removeErr
	}
	return j.hardUntrustJournal.Remove(entry)
}

type trustReuseListFailureStore struct {
	store.Store
}

func (s *trustReuseListFailureStore) ListProviderTrustReuse(context.Context) ([]store.ProviderTrustReuse, error) {
	return nil, errors.New("simulated trust-reuse list outage")
}

func durableTrustReuseTestServer(t *testing.T, st store.Store, journalPath string) *Server {
	t.Helper()
	logger := quietLogger()
	return NewServer(registry.New(logger), st, ServerConfig{
		DurableTrustReuse:     true,
		TrustReuseJournalPath: journalPath,
	}, logger)
}

func TestTrustReuseJournalPathPrecedence(t *testing.T) {
	t.Setenv(envTrustReuseRevocationJournal, "")
	t.Setenv("USER_PERSISTENT_DATA_PATH", "")
	if got := resolveTrustReuseRevocationJournalPath(); got != filepath.Join("/mnt/disks/userdata", "coordinator", trustReuseJournalFilename) {
		t.Fatalf("default journal path = %q", got)
	}
	t.Setenv("USER_PERSISTENT_DATA_PATH", "/persistent")
	if got := resolveTrustReuseRevocationJournalPath(); got != filepath.Join("/persistent", "coordinator", trustReuseJournalFilename) {
		t.Fatalf("persistent-root journal path = %q", got)
	}
	t.Setenv(envTrustReuseRevocationJournal, "/override/revocations.jsonl")
	if got := resolveTrustReuseRevocationJournalPath(); got != "/override/revocations.jsonl" {
		t.Fatalf("override journal path = %q", got)
	}
}

// TestCloseJournalLockPropagatesCloseError (review finding 5): withProcessLock
// must surface a lock-file Close failure through its named return when the
// guarded operation itself succeeded — and must never mask an earlier error.
func TestCloseJournalLockPropagatesCloseError(t *testing.T) {
	open := func() *os.File {
		f, err := os.CreateTemp(t.TempDir(), "journal-lock")
		if err != nil {
			t.Fatalf("create temp lock: %v", err)
		}
		return f
	}

	// Successful close leaves a nil error untouched.
	var err error
	closeJournalLock(open(), &err)
	if err != nil {
		t.Fatalf("clean close must not set an error, got %v", err)
	}

	// A Close failure (already-closed file) is propagated when fn succeeded.
	f := open()
	_ = f.Close()
	err = nil
	closeJournalLock(f, &err)
	if err == nil || !strings.Contains(err.Error(), "close trust-reuse journal lock") {
		t.Fatalf("close failure was swallowed, got %v", err)
	}

	// An earlier error from the guarded operation wins over the close error.
	f = open()
	_ = f.Close()
	earlier := errors.New("guarded operation failed")
	err = earlier
	closeJournalLock(f, &err)
	if !errors.Is(err, earlier) {
		t.Fatalf("close failure masked the earlier error, got %v", err)
	}

	// End-to-end: the happy path through withProcessLock still returns nil.
	journal := newFileHardUntrustJournal(filepath.Join(t.TempDir(), "revocations.jsonl"))
	if err := journal.withProcessLock(func() error { return nil }); err != nil {
		t.Fatalf("withProcessLock happy path: %v", err)
	}
}

func TestTrustAuthorityRejectsConcurrentCoordinator(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator", trustReuseJournalFilename)
	st := store.NewMemory(store.Config{})
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

func TestHardUntrustJournalAppendIsFsyncBackedBoundedAndIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator", trustReuseJournalFilename)
	first := newFileHardUntrustJournal(path)
	second := newFileHardUntrustJournal(path)
	if err := first.Initialize(); err != nil {
		t.Fatalf("Initialize: %v", err)
	}

	const seKey = "secret-se-public-key"
	entry := newHardUntrustJournalEntry(seKey, uuid.NewString())
	var wg sync.WaitGroup
	for _, journal := range []*fileHardUntrustJournal{first, second} {
		wg.Add(1)
		go func(j *fileHardUntrustJournal) {
			defer wg.Done()
			if _, err := j.Append(entry); err != nil {
				t.Errorf("Append: %v", err)
			}
		}(journal)
	}
	wg.Wait()

	entries, err := first.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(entries) != 1 || entries[0] != entry {
		t.Fatalf("idempotent entries = %+v", entries)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if strings.Contains(string(data), seKey) || !strings.Contains(string(data), hashSEPublicKey(seKey)) {
		t.Fatalf("journal leaked raw identity or omitted digest: %q", data)
	}
	for _, filename := range []string{path, path + ".lock"} {
		info, err := os.Stat(filename)
		if err != nil {
			t.Fatalf("Stat(%s): %v", filename, err)
		}
		if got := info.Mode().Perm(); got != 0o600 {
			t.Fatalf("mode(%s) = %o, want 600", filename, got)
		}
	}
}

func TestHardUntrustJournalMalformedLineFailsClosed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator", trustReuseJournalFilename)
	journal := newFileHardUntrustJournal(path)
	if err := journal.Initialize(); err != nil {
		t.Fatalf("Initialize: %v", err)
	}
	if err := os.WriteFile(path, []byte("{not-json}\n"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	srv := durableTrustReuseTestServer(t, store.NewMemory(store.Config{}), path)
	if err := srv.SeedTrustReuseCache(context.Background()); err == nil {
		t.Fatal("malformed journal must fail startup seeding")
	}
	blocked, reason := srv.trustSafetyStatus()
	if !blocked || reason != trustSafetyJournalHealthReason {
		t.Fatalf("trust safety = blocked:%v reason:%q", blocked, reason)
	}
}

func TestHardUntrustJournalAppendFailureLatchesRoutingClosed(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	path := filepath.Join(t.TempDir(), "coordinator", trustReuseJournalFilename)
	srv := durableTrustReuseTestServer(t, mem, path)
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("SeedTrustReuseCache: %v", err)
	}
	srv.trustReuseJournal = &failingJournal{
		hardUntrustJournal: srv.trustReuseJournal,
		appendErr:          errors.New("simulated fsync failure"),
	}
	rec := hardwareReuseRecord("se-append-fail", "SER-A", trHashA, time.Now())
	srv.trustReuseCache.recordTrust(rec)
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("UpsertProviderTrustReuse: %v", err)
	}

	srv.invalidateTrustReuse(rec.SEPubKey)
	blocked, reason := srv.trustSafetyStatus()
	if !blocked || reason != trustSafetyJournalHealthReason {
		t.Fatalf("append failure latch = blocked:%v reason:%q", blocked, reason)
	}
	if _, ok := srv.trustReuseCache.reuseTrust(rec.SEPubKey, rec.Serial, trHashA); ok {
		t.Fatal("append failure retained reusable evidence")
	}
	ready := doReq(srv, http.MethodGet, "/readyz", "", "")
	if ready.Code != http.StatusServiceUnavailable ||
		!strings.Contains(ready.Body.String(), trustSafetyJournalHealthReason) {
		t.Fatalf("readyz did not expose fixed trust-safety reason: status=%d body=%s",
			ready.Code, ready.Body.String())
	}
	routed := doReq(srv, http.MethodPost, "/v1/chat/completions", "", minimalChatBody)
	if routed.Code != http.StatusTooManyRequests {
		t.Fatalf("trust-safety latch allowed inference routing: status=%d body=%s",
			routed.Code, routed.Body.String())
	}
}

func TestHardUntrustJournalCleanupFailureLeavesPendingDenial(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	path := filepath.Join(t.TempDir(), "coordinator", trustReuseJournalFilename)
	srv := durableTrustReuseTestServer(t, mem, path)
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("SeedTrustReuseCache: %v", err)
	}
	srv.trustReuseJournal = &failingJournal{
		hardUntrustJournal: srv.trustReuseJournal,
		removeErr:          errors.New("simulated rename failure"),
	}
	rec := hardwareReuseRecord("se-cleanup-fail", "SER-C", trHashA, time.Now())
	srv.trustReuseCache.recordTrust(rec)
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("UpsertProviderTrustReuse: %v", err)
	}

	srv.invalidateTrustReuse(rec.SEPubKey)
	entries, err := srv.trustReuseJournal.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(entries) != 1 || entries[0].SEKeySHA256 != hashSEPublicKey(rec.SEPubKey) {
		t.Fatalf("cleanup failure did not retain exact entry: %+v", entries)
	}
	if !srv.trustReuseIdentityPending(rec.SEPubKey) {
		t.Fatal("cleanup failure identity is not denied")
	}
	rows, _ := mem.ListProviderTrustReuse(context.Background())
	if len(rows) != 1 || rows[0].RevokedAt == nil {
		t.Fatalf("authoritative tombstone missing after cleanup failure: %+v", rows)
	}
}

func TestHardUntrustJournalStoreOutageKeepsPendingAndBlocksReplay(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	path := filepath.Join(t.TempDir(), "coordinator", trustReuseJournalFilename)
	journal := newFileHardUntrustJournal(path)
	if err := journal.Initialize(); err != nil {
		t.Fatalf("Initialize: %v", err)
	}
	entry := newHardUntrustJournalEntry("se-store-outage", uuid.NewString())
	if _, err := journal.Append(entry); err != nil {
		t.Fatalf("Append: %v", err)
	}

	srv := durableTrustReuseTestServer(t, &trustReuseListFailureStore{Store: mem}, path)
	if err := srv.SeedTrustReuseCache(context.Background()); err == nil {
		t.Fatal("pending revocation plus store outage must fail startup replay")
	}
	blocked, reason := srv.trustSafetyStatus()
	if !blocked || reason != trustSafetyReplayHealthReason {
		t.Fatalf("replay outage safety = blocked:%v reason:%q", blocked, reason)
	}
	remaining, err := journal.Load()
	if err != nil || len(remaining) != 1 || remaining[0] != entry {
		t.Fatalf("store outage consumed pending journal entry: %+v, err=%v", remaining, err)
	}
	if !srv.trustReuseIdentityPending("se-store-outage") {
		t.Fatal("store outage did not retain identity-level fast-skip denial")
	}
}

func TestHardUntrustJournalReviewerTraceThreeFailuresRestartRecovery(t *testing.T) {
	oldBackoff := trustReuseDeleteRetryBackoff
	trustReuseDeleteRetryBackoff = time.Millisecond
	defer func() { trustReuseDeleteRetryBackoff = oldBackoff }()

	mem := store.NewMemory(store.Config{})
	flaky := &flakyDeleteStore{Store: mem, failFirst: 3}
	path := filepath.Join(t.TempDir(), "coordinator", trustReuseJournalFilename)
	rec := hardwareReuseRecord("se-reviewer-trace", "SER-R", trHashA, time.Now())
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	beforeRestart := durableTrustReuseTestServer(t, flaky, path)
	if err := beforeRestart.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("initial SeedTrustReuseCache: %v", err)
	}
	beforeRestart.invalidateTrustReuse(rec.SEPubKey)
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
	if afterRestart.trustReuseCache.hasFreshRecord(rec.SEPubKey, rec.Serial) {
		t.Fatal("stale pre-untrust row seeded after restart")
	}
	if _, ok := afterRestart.trustReuseCache.reuseTrust(rec.SEPubKey, rec.Serial, trHashA); ok {
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
	oldDeleteBackoff := trustReuseDeleteRetryBackoff
	oldReplayBackoff := trustReuseReplayInitialBackoff
	trustReuseDeleteRetryBackoff = time.Millisecond
	trustReuseReplayInitialBackoff = time.Millisecond
	defer func() {
		trustReuseDeleteRetryBackoff = oldDeleteBackoff
		trustReuseReplayInitialBackoff = oldReplayBackoff
	}()

	mem := store.NewMemory(store.Config{})
	flaky := &flakyDeleteStore{Store: mem, failFirst: 3}
	path := filepath.Join(t.TempDir(), "coordinator", trustReuseJournalFilename)
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
	srv.invalidateTrustReuse(rec.SEPubKey)
	if blocked, reason := srv.trustSafetyStatus(); !blocked ||
		reason != trustSafetyReplayHealthReason {
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
		blocked, _ := srv.trustSafetyStatus()
		return !blocked
	}) {
		t.Fatal("runtime revocation replay did not tombstone, clean journal, and restore readiness")
	}
}
