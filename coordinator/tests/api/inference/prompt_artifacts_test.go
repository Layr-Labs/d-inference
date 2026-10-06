package inference_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCatalogReconcileProvisionsPromptArtifacts(t *testing.T) {
	server := inference.New(inference.Dependencies{Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}, inference.Config{})
	status := provisionPromptArtifact(t, server, "fixture-model")
	if status.PromptContractID == "" || status.Path == "" {
		t.Fatalf("ready status omitted identity or path: %+v", status)
	}
}

// provisionPromptArtifact reconciles one catalog model whose only prompt file
// is served by a local origin, and returns its status once it is ready.
func provisionPromptArtifact(t *testing.T, server *inference.Owner, modelID string) promptcontract.ProvisionStatus {
	t.Helper()
	const (
		r2Prefix = "models/fixture"
		filePath = "tokenizer.json"
	)
	body := []byte(`{"version":"1.0"}`)
	digest := sha256.Sum256(body)
	aggregate := sha256.Sum256(digest[:])

	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/"+r2Prefix+"/"+filePath {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(body)
	}))
	t.Cleanup(origin.Close)
	baseURL, err := url.Parse(origin.URL + "/")
	if err != nil {
		t.Fatal(err)
	}

	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = filepath.Walk(root, func(path string, _ os.FileInfo, _ error) error {
			return os.Chmod(path, 0o700)
		})
	})
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
		Root:       root,
		BaseURL:    baseURL,
		HTTPClient: origin.Client(),
		AllowHTTP:  true,
	})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := promptcontract.NewProvisioner(
		context.Background(),
		cache,
		promptcontract.ProvisionerConfig{MaxConcurrent: 1, MaxModels: 1})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(provisioner.Close)

	server.SetPromptArtifactProvisioner(provisioner)
	server.ReconcilePromptArtifacts([]store.ModelRegistryRecord{{
		ModelRegistryEntry: store.ModelRegistryEntry{ID: modelID},
		ActiveVersion: &store.ModelVersion{
			R2Prefix:        r2Prefix,
			AggregateSHA256: hex.EncodeToString(aggregate[:]),
		},
		Files: []store.ModelVersionFile{{
			Path: filePath, SizeBytes: int64(len(body)), SHA256: hex.EncodeToString(digest[:]), Role: "tokenizer",
		}},
	}})

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if status, ok := server.PromptArtifactStatus(modelID); ok && status.ArtifactReady {
			return status
		}
		time.Sleep(10 * time.Millisecond)
	}
	status, _ := server.PromptArtifactStatus(modelID)
	t.Fatalf("catalog prompt artifacts did not become ready: %+v", status)
	return promptcontract.ProvisionStatus{}
}
