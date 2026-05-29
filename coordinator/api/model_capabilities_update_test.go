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

// Admins can update a model's capabilities in place, which flows through to the
// OpenRouter feed's supported_features.
func TestAdminUpdateModelCapabilities(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const modelID = "mlx-community/gpt-oss-20b"
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "GPT-OSS 20B", Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 8192, MinRAMGB: 24,
		Capabilities: []string{"chat"}, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}

	// Update capabilities via the admin action (note dupes + whitespace get normalized).
	body, _ := json.Marshal(map[string]any{"capabilities": []string{"tools", " reasoning ", "tools", ""}})
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+modelID+"/capabilities", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("update status = %d body = %s", rec.Code, rec.Body.String())
	}

	rec2, err := st.GetModelRegistryRecord(modelID)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"tools", "reasoning"}
	if len(rec2.Capabilities) != 2 || rec2.Capabilities[0] != "tools" || rec2.Capabilities[1] != "reasoning" {
		t.Fatalf("capabilities = %v, want %v", rec2.Capabilities, want)
	}

	// Confirm it lights up supported_features in the OpenRouter mapping.
	feats := supportedFeaturesFromCapabilities(rec2.Capabilities)
	if !containsStr(feats, "tools") || !containsStr(feats, "reasoning") {
		t.Errorf("supported_features = %v, want tools+reasoning", feats)
	}

	// Missing body field is rejected.
	bad := httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+modelID+"/capabilities", bytes.NewReader([]byte(`{}`)))
	bad.Header.Set("Authorization", "Bearer publish-secret")
	badRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(badRec, bad)
	if badRec.Code != http.StatusBadRequest {
		t.Errorf("missing capabilities status = %d, want 400", badRec.Code)
	}
}

// The admin key also authorizes registry actions (capabilities update here).
func TestAdminKeyAuthorizesCapabilitiesUpdate(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetAdminKey("admin-key")

	const modelID = "mlx-community/gemma-4-26b"
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "Gemma 4 26B", Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 8192, MinRAMGB: 32,
		Capabilities: []string{"chat"}, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}

	body, _ := json.Marshal(map[string]any{"capabilities": []string{"tools", "reasoning"}})
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+modelID+"/capabilities", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-key")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("admin-key update status = %d body = %s", rec.Code, rec.Body.String())
	}
	rec2, _ := st.GetModelRegistryRecord(modelID)
	if len(rec2.Capabilities) != 2 {
		t.Fatalf("capabilities = %v, want [tools reasoning]", rec2.Capabilities)
	}

	// A wrong key is still rejected.
	bad := httptest.NewRequest(http.MethodPost, "/v1/admin/models/"+modelID+"/capabilities", bytes.NewReader(body))
	bad.Header.Set("Authorization", "Bearer wrong-key")
	badRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(badRec, bad)
	if badRec.Code != http.StatusUnauthorized {
		t.Errorf("wrong key status = %d, want 401", badRec.Code)
	}
}
