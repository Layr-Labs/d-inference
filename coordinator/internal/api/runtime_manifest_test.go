package api

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

func runtimeManifestTestServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	return srv, st
}

func TestSyncRuntimeManifestUsesLatestReleaseOnly(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)

	if err := st.SetRelease(&store.Release{
		Version:         "0.3.8",
		Platform:        "macos-arm64",
		BinaryHash:      "old-binary",
		BundleHash:      "old-bundle",
		PythonHash:      "old-python",
		RuntimeHash:     "old-runtime",
		TemplateHashes:  "qwen3.5=old-template",
		GrpcBinaryHash:  "old-grpc",
		ImageBridgeHash: "old-image-bridge",
		URL:             "https://example.com/old.tar.gz",
		Active:          true,
	}); err != nil {
		t.Fatalf("SetRelease(old): %v", err)
	}

	if err := st.SetRelease(&store.Release{
		Version:         "0.3.9",
		Platform:        "macos-arm64",
		BinaryHash:      "new-binary",
		BundleHash:      "new-bundle",
		PythonHash:      "new-python",
		RuntimeHash:     "new-runtime",
		TemplateHashes:  "qwen3.5=new-template,minimax=new-minimax-template",
		GrpcBinaryHash:  "new-grpc",
		ImageBridgeHash: "new-image-bridge",
		URL:             "https://example.com/new.tar.gz",
		Active:          true,
	}); err != nil {
		t.Fatalf("SetRelease(new): %v", err)
	}

	srv.SyncRuntimeManifest()

	if srv.minProviderVersion != "0.3.9" {
		t.Fatalf("minProviderVersion = %q, want %q", srv.minProviderVersion, "0.3.9")
	}
	if srv.knownRuntimeManifest == nil {
		t.Fatal("knownRuntimeManifest = nil")
	}

	manifest := srv.knownRuntimeManifest
	if !manifest.PythonHashes["new-python"] {
		t.Fatal("latest python hash missing from runtime manifest")
	}
	if manifest.PythonHashes["old-python"] {
		t.Fatal("stale python hash should not remain in runtime manifest")
	}
	if !manifest.RuntimeHashes["new-runtime"] {
		t.Fatal("latest runtime hash missing from runtime manifest")
	}
	if manifest.RuntimeHashes["old-runtime"] {
		t.Fatal("stale runtime hash should not remain in runtime manifest")
	}
	if got := manifest.TemplateHashes["qwen3.5"]; got != "new-template" {
		t.Fatalf("qwen3.5 template hash = %q, want %q", got, "new-template")
	}
	if got := manifest.TemplateHashes["minimax"]; got != "new-minimax-template" {
		t.Fatalf("minimax template hash = %q, want %q", got, "new-minimax-template")
	}
	if !manifest.GrpcBinaryHashes["new-grpc"] {
		t.Fatal("latest gRPC hash missing from runtime manifest")
	}
	if manifest.GrpcBinaryHashes["old-grpc"] {
		t.Fatal("stale gRPC hash should not remain in runtime manifest")
	}
	if !manifest.ImageBridgeHashes["new-image-bridge"] {
		t.Fatal("latest image bridge hash missing from runtime manifest")
	}
	if manifest.ImageBridgeHashes["old-image-bridge"] {
		t.Fatal("stale image bridge hash should not remain in runtime manifest")
	}
}

func TestSyncRuntimeManifestClearsStaleHashesWhenLatestReleaseHasNoRuntimeMetadata(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)

	if err := st.SetRelease(&store.Release{
		Version:        "0.3.8",
		Platform:       "macos-arm64",
		BinaryHash:     "old-binary",
		BundleHash:     "old-bundle",
		PythonHash:     "old-python",
		RuntimeHash:    "old-runtime",
		TemplateHashes: "qwen3.5=old-template",
		URL:            "https://example.com/old.tar.gz",
		Active:         true,
	}); err != nil {
		t.Fatalf("SetRelease(old): %v", err)
	}

	srv.SyncRuntimeManifest()
	if srv.knownRuntimeManifest == nil {
		t.Fatal("expected initial runtime manifest")
	}

	if err := st.SetRelease(&store.Release{
		Version:    "0.3.9",
		Platform:   "macos-arm64",
		BinaryHash: "new-binary",
		BundleHash: "new-bundle",
		URL:        "https://example.com/new.tar.gz",
		Active:     true,
	}); err != nil {
		t.Fatalf("SetRelease(new): %v", err)
	}

	srv.SyncRuntimeManifest()

	if srv.minProviderVersion != "0.3.9" {
		t.Fatalf("minProviderVersion = %q, want %q", srv.minProviderVersion, "0.3.9")
	}
	if srv.knownRuntimeManifest != nil {
		t.Fatal("knownRuntimeManifest should be cleared when latest release has no runtime metadata")
	}
}
