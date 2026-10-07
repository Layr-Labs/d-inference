package trust_test

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	trustjournal "github.com/eigeninference/d-inference/coordinator/internal/provider/journal"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/journal/lockfile"
	"github.com/google/uuid"
)

func TestTrustReuseJournalPathPrecedence(t *testing.T) {
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_REVOCATION_JOURNAL_PATH",

		"")
	t.Setenv("USER_PERSISTENT_DATA_PATH", "")
	if got := trustjournal.ResolveTrustReuseRevocationJournalPath(); got != filepath.Join("/mnt/disks/userdata", "coordinator", "trust-reuse-hard-untrust.v1.jsonl") {
		t.Fatalf("default journal path = %q", got)
	}
	t.Setenv("USER_PERSISTENT_DATA_PATH", "/persistent")
	if got := trustjournal.ResolveTrustReuseRevocationJournalPath(); got != filepath.Join("/persistent", "coordinator", "trust-reuse-hard-untrust.v1.jsonl") {
		t.Fatalf("persistent-root journal path = %q", got)
	}
	t.Setenv("EIGENINFERENCE_TRUST_REUSE_REVOCATION_JOURNAL_PATH",

		"/override/revocations.jsonl")
	if got := trustjournal.ResolveTrustReuseRevocationJournalPath(); got != "/override/revocations.jsonl" {
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
	lockfile.Close(open(), &err)
	if err != nil {
		t.Fatalf("clean close must not set an error, got %v", err)
	}

	// A Close failure (already-closed file) is propagated when fn succeeded.
	f := open()
	_ = f.Close()
	err = nil
	lockfile.Close(f, &err)
	if err == nil || !strings.Contains(err.Error(), "close trust-reuse journal lock") {
		t.Fatalf("close failure was swallowed, got %v", err)
	}

	// An earlier error from the guarded operation wins over the close error.
	f = open()
	_ = f.Close()
	earlier := errors.New("guarded operation failed")
	err = earlier
	lockfile.Close(f, &err)
	if !errors.Is(err, earlier) {
		t.Fatalf("close failure masked the earlier error, got %v", err)
	}

	// End-to-end: the happy path through withProcessLock still returns nil.
	journal := trustjournal.NewFile(filepath.Join(t.TempDir(), "revocations.jsonl"))
	if err := lockfile.WithProcessLock(journal.Path()+".lock", 5*time.Second, func() error { return nil }); err != nil {
		t.Fatalf("withProcessLock happy path: %v", err)
	}
}

func TestHardUntrustJournalAppendIsFsyncBackedBoundedAndIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	first := trustjournal.NewFile(path)
	second := trustjournal.NewFile(path)
	if err := first.Initialize(); err != nil {
		t.Fatalf("Initialize: %v", err)
	}

	const seKey = "secret-se-public-key"
	entry := trustjournal.NewEntry(seKey, uuid.NewString())
	var wg sync.WaitGroup
	for _, journal := range []*trustjournal.File{first, second} {
		wg.Add(1)
		go func(j *trustjournal.File) {
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
	// The entry embeds BOTH the digest (row matching, legacy compat) and the
	// plaintext SE public key (Codex P2: row-less tombstone creation on crash
	// replay). The SE public key is not confidential — the store keeps it
	// plaintext in provider_trust_reuse — and the file stays 0600 below.
	if !strings.Contains(string(data), trustjournal.HashSEPublicKey(seKey)) ||
		!strings.Contains(string(data), "\"se_pub_key\":\""+seKey+"\"") {
		t.Fatalf("journal entry must carry the digest and the bound SE key: %q", data)
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
