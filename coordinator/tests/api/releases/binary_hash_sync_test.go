package releases_test

import (
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestSyncBinaryHashesRejectsInvalidStoredReleaseHashWithoutFailingOpen(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := releaseOwnerFixture(reg, st, logger)
	if err := st.SetRelease(&store.Release{
		Version:    "1.0.0",
		Platform:   "macos-arm64",
		BinaryHash: "not-a-sha256",
		BundleHash: strings.Repeat("b", 64),
		URL:        "https://r2.example.com/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz",
	}); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}

	srv.SyncBinaryHashes()

	policyConfigured, knownHashes := srv.BinaryHashPolicySnapshot()
	if !policyConfigured {
		t.Fatal("binary hash policy should remain configured when an active release has an invalid hash")
	}
	if len(knownHashes) != 0 {
		t.Fatalf("known binary hashes = %d, want 0 valid hashes", len(knownHashes))
	}
}

func TestSyncBinaryHashesPreservesAdditionalConfiguredHashes(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := releaseOwnerFixture(reg, st, logger)

	manualHash := strings.Repeat("a", 64)
	releaseHash := strings.Repeat("b", 64)
	srv.AddKnownBinaryHashes([]string{manualHash})
	if err := st.SetRelease(&store.Release{
		Version:    "1.0.0",
		Platform:   "macos-arm64",
		BinaryHash: releaseHash,
		BundleHash: strings.Repeat("c", 64),
		URL:        "https://r2.example.com/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz",
	}); err != nil {
		t.Fatalf("SetRelease: %v", err)
	}

	srv.SyncBinaryHashes()
	policyConfigured, knownHashes := srv.BinaryHashPolicySnapshot()
	if !policyConfigured {
		t.Fatal("binary hash policy should be configured after manual hash and active release")
	}
	if !knownHashes[manualHash] {
		t.Fatal("manual binary hash was dropped during release sync")
	}
	if !knownHashes[releaseHash] {
		t.Fatal("release binary hash was not synced")
	}

	if err := st.DeleteRelease("1.0.0", "macos-arm64"); err != nil {
		t.Fatalf("DeleteRelease: %v", err)
	}
	srv.SyncBinaryHashes()
	policyConfigured, knownHashes = srv.BinaryHashPolicySnapshot()
	if !policyConfigured {
		t.Fatal("binary hash policy should remain configured after release deletion because manual hash remains")
	}
	if !knownHashes[manualHash] {
		t.Fatal("manual binary hash was dropped during release deletion sync")
	}
	if knownHashes[releaseHash] {
		t.Fatal("inactive release binary hash should not remain after sync")
	}
}

func TestBinaryHashPolicySnapshotConcurrentSync(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := releaseOwnerFixture(reg, st, logger)
	manualHash := strings.Repeat("a", 64)
	srv.AddKnownBinaryHashes([]string{manualHash})

	done := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-done:
					return
				default:
					policyConfigured, knownHashes := srv.BinaryHashPolicySnapshot()
					if policyConfigured && !knownHashes[manualHash] {
						t.Errorf("manual hash missing from policy snapshot")
						return
					}
				}
			}
		}()
	}

	for i := 0; i < 50; i++ {
		version := fmt.Sprintf("1.0.%d", i)
		releaseHash := fmt.Sprintf("%064x", i+1)
		if err := st.SetRelease(&store.Release{
			Version:    version,
			Platform:   "macos-arm64",
			BinaryHash: releaseHash,
			BundleHash: strings.Repeat("c", 64),
			URL:        "https://r2.example.com/releases/v" + version + "/darkbloom-bundle-macos-arm64.tar.gz",
		}); err != nil {
			t.Fatalf("SetRelease: %v", err)
		}
		srv.SyncBinaryHashes()
		if err := st.DeleteRelease(version, "macos-arm64"); err != nil {
			t.Fatalf("DeleteRelease: %v", err)
		}
		srv.SyncBinaryHashes()
	}

	close(done)
	wg.Wait()
}
