package releasepolicy

import (
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestSyncRuntimeManifestWithoutRegistry(t *testing.T) {
	inventory := store.NewMemory(store.Config{})
	metallibHash := strings.Repeat("a", 64)
	if err := inventory.SetRelease(&store.Release{
		Version:      "0.8.16",
		Platform:     "macos-arm64",
		MetallibHash: metallibHash,
	}); err != nil {
		t.Fatal(err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	manager := New(Dependencies{
		Store:    func() Store { return inventory },
		Registry: func() Registry { return nil },
		Logger:   func() *slog.Logger { return logger },
	})

	if err := manager.SyncRuntimeManifest(); err != nil {
		t.Fatalf("sync active release without registry: %v", err)
	}
	manifest := manager.RuntimeManifest()
	if manifest == nil || !RuntimeManifestApprovesMetallib(manifest, map[string]string{"mlx_metallib": metallibHash}) {
		t.Fatalf("active release was not published without registry: %#v", manifest)
	}

	if err := inventory.DeleteRelease("0.8.16", "macos-arm64"); err != nil {
		t.Fatal(err)
	}
	if err := manager.SyncRuntimeManifest(); err != nil {
		t.Fatalf("sync withdrawn release without registry: %v", err)
	}
	if manifest := manager.RuntimeManifest(); manifest != nil {
		t.Fatalf("withdrawn release retained a runtime manifest: %#v", manifest)
	}
}
