package analyticssnapshot_test

import (
	"bytes"
	. "github.com/eigeninference/d-inference/coordinator/analyticssnapshot"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPersistentAcceptanceRejectsRollbackAfterRestart(t *testing.T) {
	now := time.Date(2026, 9, 29, 12, 0, 30, 0, time.UTC)
	dir := t.TempDir()
	snapshotPath := filepath.Join(dir, "current.json")
	statePath := filepath.Join(dir, "accepted.json")
	first := fixture(now)
	if err := os.WriteFile(snapshotPath, data(t, first), 0o600); err != nil {
		t.Fatal(err)
	}
	var cache Cache
	if err := cache.LoadPersistent(snapshotPath, statePath, now); err == nil {
		t.Fatal("bootstrapped from a missing accepted-state file")
	}
	if err := os.WriteFile(statePath, []byte(`{"version":1,"checksums":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := cache.LoadPersistent(snapshotPath, statePath, now); err != nil {
		t.Fatal(err)
	}
	second := fixture(now)
	second.Generation = "second"
	second.AsOf = second.AsOf.Add(time.Second)
	second.SourceCompleteThrough = second.SourceCompleteThrough.Add(time.Second)
	if err := os.WriteFile(snapshotPath, data(t, second), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := cache.LoadPersistent(snapshotPath, statePath, now); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(statePath); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("accepted state permissions: %v, %v", info, err)
	}
	if err := os.WriteFile(snapshotPath, data(t, first), 0o600); err != nil {
		t.Fatal(err)
	}
	var restarted Cache
	if err := restarted.LoadPersistent(snapshotPath, statePath, now); err == nil {
		t.Fatal("accepted an older still-fresh pointer after restart")
	}
	if _, ok := restarted.Get(now); ok {
		t.Fatal("served a rejected rollback")
	}
	if err := os.WriteFile(snapshotPath, data(t, second), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := restarted.LoadPersistent(snapshotPath, statePath, now); err != nil {
		t.Fatal("reloading the accepted generation must work", err)
	}
	if got, ok := restarted.Get(now); !ok || got.Generation != second.Generation {
		t.Fatal("failed to serve the durable accepted generation")
	}
	third := fixture(now)
	third.Generation = first.Generation
	third.AsOf = third.AsOf.Add(2 * time.Second)
	third.SourceCompleteThrough = third.SourceCompleteThrough.Add(2 * time.Second)
	if err := os.WriteFile(snapshotPath, data(t, third), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := restarted.LoadPersistent(snapshotPath, statePath, now); err == nil {
		t.Fatal("reused an older generation with changed content after restart")
	}
}

func TestPersistentAcceptanceFailsClosedOnCorruptOrExposedState(t *testing.T) {
	now := time.Date(2026, 9, 29, 12, 0, 30, 0, time.UTC)
	dir := t.TempDir()
	snapshotPath := filepath.Join(dir, "current.json")
	statePath := filepath.Join(dir, "accepted.json")
	if err := os.WriteFile(snapshotPath, data(t, fixture(now)), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name string
		data []byte
		mode os.FileMode
	}{
		{"malformed", []byte("not-json"), 0o600},
		{"missing history", []byte(`{"version":1,"latest_generation":"prior","checksums":{}}`), 0o600},
		{"world readable", []byte(`{"version":1,"checksums":{}}`), 0o644},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.WriteFile(statePath, tc.data, tc.mode); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(statePath, tc.mode); err != nil {
				t.Fatal(err)
			}
			var cache Cache
			if err := cache.LoadPersistent(snapshotPath, statePath, now); err == nil {
				t.Fatal("accepted invalid durable state")
			}
			if _, ok := cache.Get(now); ok {
				t.Fatal("served a snapshot after state validation failed")
			}
		})
	}
	if err := os.WriteFile(statePath, []byte(`{"version":1,"checksums":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(statePath, 0o600); err != nil {
		t.Fatal(err)
	}
	var cache Cache
	if err := cache.LoadPersistent(snapshotPath, statePath, now); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(mustReadFile(t, statePath), []byte(`"latest_generation":"generation1"`)) {
		t.Fatal("accepted generation was not persisted")
	}
}

func mustReadFile(t *testing.T, path string) []byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
