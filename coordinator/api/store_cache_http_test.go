package api

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The production store is wrapped in the read-through cache (store.NewCached,
// see cmd/coordinator/main.go). This exercises the cache through the real HTTP
// path: the admin runtime-parameters action READS the model record, merges,
// and WRITES it back — so a second update must observe the first one. With a
// stale cache the second response would silently drop the first parameter.
func TestStoreCacheInvalidatesThroughAdminModelAction(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	cached := store.NewCached(store.NewMemory(store.Config{}), store.DefaultCacheConfig())
	reg := registry.New(logger)
	srv := NewServer(reg, cached, ServerConfig{}, logger)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	const modelID = "mlx-community/cache-probe-4bit"
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "Cache Probe", Quantization: "4bit",
		MaxContextLength: 32768, MaxOutputLength: 4096, MinRAMGB: 16,
		Capabilities: []string{"chat"}, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := cached.SetModelVersion(entry, &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := cached.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}

	// Warm the cache with a read through the store, exactly as the chat path does.
	if _, err := cached.GetModelRegistryRecord(modelID); err != nil {
		t.Fatalf("warm read: %v", err)
	}

	post := func(params map[string]any) map[string]any {
		t.Helper()
		body, _ := json.Marshal(map[string]any{"runtime_parameters": params})
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/admin/models/"+modelID+"/runtime-parameters", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer publish-secret")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("runtime-parameters status = %d", resp.StatusCode)
		}
		var out struct {
			RuntimeParameters map[string]any `json:"runtime_parameters"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatal(err)
		}
		return out.RuntimeParameters
	}

	post(map[string]any{"temperature": 0.2})
	got := post(map[string]any{"top_p": 0.9})
	if _, ok := got["temperature"]; !ok {
		t.Fatalf("second update lost the first parameter — stale cached record served through HTTP: %v", got)
	}
	if _, ok := got["top_p"]; !ok {
		t.Fatalf("second update missing its own parameter: %v", got)
	}

	// The store view agrees, and the cache is serving hits again after the writes.
	rec, err := cached.GetModelRegistryRecord(modelID)
	if err != nil {
		t.Fatal(err)
	}
	if rec.RuntimeParameters["temperature"] == nil || rec.RuntimeParameters["top_p"] == nil {
		t.Fatalf("store record = %v", rec.RuntimeParameters)
	}
	stats := cached.Stats()
	if stats.Models.Invalidations == 0 {
		t.Fatalf("expected model-domain invalidations from the admin writes, stats = %+v", stats.Models)
	}
	if stats.Models.Hits == 0 {
		t.Fatalf("expected cache hits after warm read, stats = %+v", stats.Models)
	}
}
