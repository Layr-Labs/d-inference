package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// TestListModelsOpenRouterFields verifies that GET /v1/models emits the full
// OpenRouter provider schema, sourcing metadata from the model registry and
// pricing from the platform price table.
func TestListModelsOpenRouterFields(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 500 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	const modelID = "mlx-community/Qwen3.5-9B-MLX-4bit"

	// Seed a rich registry entry + active version, then sync the routing catalog.
	entry := &store.ModelRegistryEntry{
		ID:               modelID,
		DisplayName:      "Qwen3.5 9B",
		Family:           "qwen",
		Architecture:     "9B dense",
		Quantization:     "4bit",
		MaxContextLength: 262144,
		MaxOutputLength:  16384,
		MinRAMGB:         16,
		Capabilities:     []string{"tools", "reasoning"},
		Status:           "active",
		Description:      "Balanced general-purpose model.",
		Metadata:         map[string]any{"deprecation_date": "2026-12-31"},
		CreatedAt:        time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC),
	}
	version := &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 9_000_000_000, FileCount: 1, Status: "ready"}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	// Platform pricing: $0.05 / $0.20 per 1M tokens (micro-USD).
	if err := st.SetModelPrice("platform", modelID, 50_000, 200_000); err != nil {
		t.Fatal(err)
	}

	// A trusted, private-ready provider makes the model show up in
	// registry.ListModels() (which gates on trust + E2E readiness).
	conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, modelID, testPublicKeyB64(), 50.0)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Call the handler directly (bypasses requireAuth, like the existing test).
	rec := httptest.NewRecorder()
	srv.handleListModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}

	var resp types.ModelListResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}

	var entryOut *types.ModelEntry
	for i := range resp.Data {
		if resp.Data[i].ID == modelID {
			entryOut = &resp.Data[i]
			break
		}
	}
	if entryOut == nil {
		t.Fatalf("model %q not in response: %s", modelID, rec.Body.String())
	}

	if entryOut.Name != "Qwen3.5 9B" {
		t.Errorf("name = %q, want %q", entryOut.Name, "Qwen3.5 9B")
	}
	if entryOut.HuggingFaceID != modelID {
		t.Errorf("hugging_face_id = %q, want %q", entryOut.HuggingFaceID, modelID)
	}
	if entryOut.Created != entry.CreatedAt.Unix() {
		t.Errorf("created = %d, want %d", entryOut.Created, entry.CreatedAt.Unix())
	}
	if entryOut.Quantization != "int4" {
		t.Errorf("quantization = %q, want int4", entryOut.Quantization)
	}
	if entryOut.ContextLength != 262144 {
		t.Errorf("context_length = %d, want 262144", entryOut.ContextLength)
	}
	if entryOut.MaxOutputLength != 16384 {
		t.Errorf("max_output_length = %d, want 16384", entryOut.MaxOutputLength)
	}
	if entryOut.Description != "Balanced general-purpose model." {
		t.Errorf("description = %q", entryOut.Description)
	}
	if entryOut.DeprecationDate != "2026-12-31" {
		t.Errorf("deprecation_date = %q, want 2026-12-31", entryOut.DeprecationDate)
	}
	if entryOut.Pricing == nil || entryOut.Pricing.Prompt != "0.00000005" || entryOut.Pricing.Completion != "0.0000002" {
		t.Errorf("pricing = %+v, want prompt 0.00000005 / completion 0.0000002", entryOut.Pricing)
	}
	if len(entryOut.InputModalities) == 0 || entryOut.InputModalities[0] != "text" {
		t.Errorf("input_modalities = %v, want [text]", entryOut.InputModalities)
	}
	if len(entryOut.OutputModalities) == 0 || entryOut.OutputModalities[0] != "text" {
		t.Errorf("output_modalities = %v, want [text]", entryOut.OutputModalities)
	}
	if len(entryOut.SupportedSamplingParameters) == 0 {
		t.Error("supported_sampling_parameters is empty")
	}
	if !containsStr(entryOut.SupportedFeatures, "tools") || !containsStr(entryOut.SupportedFeatures, "reasoning") {
		t.Errorf("supported_features = %v, want tools + reasoning", entryOut.SupportedFeatures)
	}
}

func containsStr(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
