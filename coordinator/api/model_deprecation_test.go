package api

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAdminSetAndClearDeprecationDate(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetAdminKey("admin-key")

	const modelID = "mlx-community/dep-model"
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "Dep Model", Quantization: "4bit",
		MaxContextLength: 8192, MaxOutputLength: 2048, MinRAMGB: 8, Status: "active",
		Metadata: map[string]any{"tier": "test"},
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}

	call := func(body string) *httptest.ResponseRecorder {
		var r *http.Request
		if body == "" {
			r = httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+modelID+"/deprecation", nil)
		} else {
			r = httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+modelID+"/deprecation", bytes.NewReader([]byte(body)))
		}
		r.Header.Set("Authorization", "Bearer admin-key")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, r)
		return rec
	}

	// Set a deprecation date.
	if rec := call(`{"deprecation_date":"2026-06-01"}`); rec.Code != http.StatusOK {
		t.Fatalf("set status = %d body = %s", rec.Code, rec.Body.String())
	}
	rec1, _ := st.GetModelRegistryRecord(modelID)
	if rec1.Metadata["deprecation_date"] != "2026-06-01" {
		t.Fatalf("metadata deprecation_date = %v", rec1.Metadata["deprecation_date"])
	}
	if rec1.Metadata["tier"] != "test" {
		t.Errorf("existing metadata clobbered: %v", rec1.Metadata)
	}

	// Invalid date rejected.
	if rec := call(`{"deprecation_date":"June 1 2026"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("invalid date status = %d, want 400", rec.Code)
	}

	// Clear by default: empty body removes it.
	if rec := call(""); rec.Code != http.StatusOK {
		t.Fatalf("clear (empty body) status = %d body = %s", rec.Code, rec.Body.String())
	}
	rec2, _ := st.GetModelRegistryRecord(modelID)
	if _, present := rec2.Metadata["deprecation_date"]; present {
		t.Errorf("deprecation_date should be cleared, metadata = %v", rec2.Metadata)
	}
	if rec2.Metadata["tier"] != "test" {
		t.Errorf("clear should preserve other metadata: %v", rec2.Metadata)
	}

	// Set again, then clear via empty string.
	_ = call(`{"deprecation_date":"2027-01-01"}`)
	if rec := call(`{"deprecation_date":""}`); rec.Code != http.StatusOK {
		t.Fatalf("clear (empty string) status = %d", rec.Code)
	}
	rec3, _ := st.GetModelRegistryRecord(modelID)
	if _, present := rec3.Metadata["deprecation_date"]; present {
		t.Error("empty-string deprecation_date should clear")
	}
}

func TestAdminSetAndClearOpenRouterSlug(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetAdminKey("admin-key")

	const modelID = "mlx-community/slug-model"
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "Slug Model", Quantization: "4bit",
		MaxContextLength: 8192, MaxOutputLength: 2048, MinRAMGB: 8, Status: "active",
		Metadata: map[string]any{"tier": "test"},
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}

	call := func(body string) *httptest.ResponseRecorder {
		var r *http.Request
		if body == "" {
			r = httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+modelID+"/openrouter-slug", nil)
		} else {
			r = httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+modelID+"/openrouter-slug", bytes.NewReader([]byte(body)))
		}
		r.Header.Set("Authorization", "Bearer admin-key")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, r)
		return rec
	}

	// Set the slug to a canonical marketplace value.
	if rec := call(`{"slug":"qwen/qwen3.5-9b"}`); rec.Code != http.StatusOK {
		t.Fatalf("set slug status = %d body = %s", rec.Code, rec.Body.String())
	}
	rec1, _ := st.GetModelRegistryRecord(modelID)
	if rec1.Metadata["openrouter_slug"] != "qwen/qwen3.5-9b" {
		t.Fatalf("metadata openrouter_slug = %v", rec1.Metadata["openrouter_slug"])
	}
	if openRouterSlug(modelID, rec1.Metadata) != "qwen/qwen3.5-9b" {
		t.Error("override should win in the feed mapping")
	}
	if rec1.Metadata["tier"] != "test" {
		t.Errorf("other metadata clobbered: %v", rec1.Metadata)
	}

	// Clear by default (empty body) → falls back to the model id.
	if rec := call(""); rec.Code != http.StatusOK {
		t.Fatalf("clear slug status = %d body = %s", rec.Code, rec.Body.String())
	}
	rec2, _ := st.GetModelRegistryRecord(modelID)
	if _, present := rec2.Metadata["openrouter_slug"]; present {
		t.Errorf("openrouter_slug should be cleared, metadata = %v", rec2.Metadata)
	}
	if got := openRouterSlug(modelID, rec2.Metadata); got != modelID {
		t.Errorf("after clear, slug = %q, want the model id", got)
	}
}
