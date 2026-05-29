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
	st := store.NewMemory("")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
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
