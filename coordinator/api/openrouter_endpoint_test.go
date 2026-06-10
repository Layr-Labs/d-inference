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

// TestOpenRouterModelsEndpoint verifies the dedicated /v1/models/openrouter feed
// emits the pure OpenRouter schema: text modalities, slug, staging-based
// is_ready, populated features, and no Darkbloom metadata block.
func TestOpenRouterModelsEndpoint(t *testing.T) {
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
	entry := &store.ModelRegistryEntry{
		ID:               modelID,
		DisplayName:      "Qwen3.5 9B",
		Quantization:     "4bit",
		MaxContextLength: 262144,
		MaxOutputLength:  16384,
		MinRAMGB:         16,
		Capabilities:     []string{"tools", "reasoning"},
		Status:           "active",
		Description:      "Balanced general-purpose model.",
		Metadata:         map[string]any{"openrouter_slug": "darkbloom/qwen3.5-9b"},
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
	if err := st.SetModelPrice("platform", modelID, 50_000, 200_000); err != nil {
		t.Fatal(err)
	}

	conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, modelID, testPublicKeyB64(), 50.0)
	defer conn.Close(websocket.StatusNormalClosure, "")

	rec := httptest.NewRecorder()
	srv.handleListModelsOpenRouter(rec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}

	var resp types.OpenRouterModelsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	var m *types.OpenRouterModel
	for i := range resp.Data {
		if resp.Data[i].ID == modelID {
			m = &resp.Data[i]
			break
		}
	}
	if m == nil {
		t.Fatalf("model not in feed: %s", rec.Body.String())
	}

	if m.Name != "Qwen3.5 9B" {
		t.Errorf("name = %q", m.Name)
	}
	if m.HuggingFaceID != modelID {
		t.Errorf("hugging_face_id = %q", m.HuggingFaceID)
	}
	if m.Created != entry.CreatedAt.Unix() {
		t.Errorf("created = %d, want %d", m.Created, entry.CreatedAt.Unix())
	}
	if len(m.InputModalities) != 1 || m.InputModalities[0] != "text" {
		t.Errorf("input_modalities = %v, want [text]", m.InputModalities)
	}
	if len(m.OutputModalities) != 1 || m.OutputModalities[0] != "text" {
		t.Errorf("output_modalities = %v, want [text]", m.OutputModalities)
	}
	if m.Quantization != "int4" {
		t.Errorf("quantization = %q, want int4", m.Quantization)
	}
	if m.ContextLength != 262144 || m.MaxOutputLength != 16384 {
		t.Errorf("context/output = %d/%d", m.ContextLength, m.MaxOutputLength)
	}
	if m.Pricing.Prompt != "0.00000005" || m.Pricing.Completion != "0.0000002" {
		t.Errorf("pricing = %+v", m.Pricing)
	}
	if !containsStr(m.SupportedFeatures, "tools") || !containsStr(m.SupportedFeatures, "reasoning") {
		t.Errorf("supported_features = %v", m.SupportedFeatures)
	}
	if len(m.SupportedSamplingParameters) == 0 {
		t.Error("supported_sampling_parameters empty")
	}
	if !m.IsReady {
		t.Error("is_ready should be true for an active model")
	}
	if m.OpenRouter == nil || m.OpenRouter.Slug != "darkbloom/qwen3.5-9b" {
		t.Errorf("slug = %+v, want darkbloom/qwen3.5-9b", m.OpenRouter)
	}

	// The pure feed must NOT carry the Darkbloom metadata block.
	var raw map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &raw)
	first := raw["data"].([]any)[0].(map[string]any)
	if _, leaked := first["metadata"]; leaked {
		t.Error("OpenRouter feed leaked internal metadata block")
	}
	if _, leaked := first["trust_level"]; leaked {
		t.Error("OpenRouter feed leaked trust_level")
	}
}

// The feed is catalog-driven: an active model stays listed even when NO provider
// is currently online for it (transient capacity is OpenRouter's concern via
// 429s, not a reason to delist). Datacenters are empty in that case.
func TestOpenRouterFeedSurvivesProviderOutage(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const modelID = "mlx-community/orphan-model"
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "Orphan", Quantization: "4bit",
		MaxContextLength: 8192, MaxOutputLength: 2048, MinRAMGB: 8, Status: "active",
		Capabilities: []string{"tools"},
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()
	// Note: NO provider connected. registry.ListModels() is empty.

	rec := httptest.NewRecorder()
	srv.handleListModelsOpenRouter(rec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
	var resp types.OpenRouterModelsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	var found *types.OpenRouterModel
	for i := range resp.Data {
		if resp.Data[i].ID == modelID {
			found = &resp.Data[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("active model must remain in the feed with no provider online: %s", rec.Body.String())
	}
	if !found.IsReady {
		t.Error("active model should be is_ready even with no provider")
	}
	if len(found.Datacenters) != 0 {
		t.Errorf("datacenters should be empty with no provider, got %v", found.Datacenters)
	}
	if found.ContextLength != 8192 || !containsStr(found.SupportedFeatures, "tools") {
		t.Errorf("registry-derived fields missing: ctx=%d feats=%v", found.ContextLength, found.SupportedFeatures)
	}
}

// Staged models (openrouter_is_ready=false) report is_ready=false.
func TestOpenRouterModelsStaging(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 500 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	const modelID = "mlx-community/Staged-Model"
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "Staged", Quantization: "4bit",
		MaxContextLength: 8192, MaxOutputLength: 2048, MinRAMGB: 8, Status: "active",
		Metadata: map[string]any{"openrouter_is_ready": false},
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()
	conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, modelID, testPublicKeyB64(), 50.0)
	defer conn.Close(websocket.StatusNormalClosure, "")

	rec := httptest.NewRecorder()
	srv.handleListModelsOpenRouter(rec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
	var resp types.OpenRouterModelsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	for _, m := range resp.Data {
		if m.ID == modelID {
			if m.IsReady {
				t.Error("staged model should report is_ready=false")
			}
			// Slug defaults to the unique model id.
			if m.OpenRouter == nil || m.OpenRouter.Slug != modelID {
				t.Errorf("default slug = %+v, want the model id %q", m.OpenRouter, modelID)
			}
			return
		}
	}
	t.Fatalf("staged model not found in feed: %s", rec.Body.String())
}

// Public aliases get the /v1/models treatment in the OpenRouter feed too: the
// alias is the purchasable entry, member builds are hidden, and the marketplace
// never sees a raw quant build that a migration will later retire.
func TestOpenRouterModelsAliasEntriesHideBuilds(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B fp8")
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B qat")
	seedActiveModel(t, st, "mlx-community/unrelated-9b", "Unrelated 9B")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	rec := httptest.NewRecorder()
	srv.handleListModelsOpenRouter(rec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
	var resp types.OpenRouterModelsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}

	byID := make(map[string]types.OpenRouterModel, len(resp.Data))
	for _, m := range resp.Data {
		byID[m.ID] = m
	}
	alias, ok := byID["gemma-4-26b"]
	if !ok {
		t.Fatalf("alias entry missing from feed: %+v", resp.Data)
	}
	if alias.Name != "Gemma 4 26B" {
		t.Fatalf("alias display name = %q", alias.Name)
	}
	// Identity (slug) is the alias — stable across build migrations. The HF id
	// stays the primary (desired) build's real HuggingFace path.
	if alias.OpenRouter == nil || alias.OpenRouter.Slug != "gemma-4-26b" {
		t.Fatalf("alias slug = %+v, want gemma-4-26b", alias.OpenRouter)
	}
	if alias.HuggingFaceID != aliasQAT {
		t.Fatalf("alias hugging_face_id = %q, want primary build", alias.HuggingFaceID)
	}
	// Member builds are hidden from the raw listing.
	if _, leaked := byID[aliasFP8]; leaked {
		t.Fatal("previous build leaked into the OpenRouter feed")
	}
	if _, leaked := byID[aliasQAT]; leaked {
		t.Fatal("desired build leaked into the OpenRouter feed")
	}
	// Unaliased models keep their raw entries.
	if _, ok := byID["mlx-community/unrelated-9b"]; !ok {
		t.Fatal("unaliased model missing from feed")
	}
}

// The OpenRouter marketplace feed must also hide a retired build: once fp8 is
// retired (moved to the lineage) it must not reappear as a sellable entry —
// otherwise OpenRouter lists it is_ready:true with zero providers, a black-hole.
func TestOpenRouterModelsHidesRetiredAliasBuild(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B fp8")
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, RetiredBuilds: []string{aliasFP8},
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	rec := httptest.NewRecorder()
	srv.handleListModelsOpenRouter(rec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
	}
	var resp types.OpenRouterModelsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	sawAlias := false
	for _, m := range resp.Data {
		if m.ID == aliasFP8 {
			t.Fatalf("retired build %q leaked into the OpenRouter feed", aliasFP8)
		}
		if m.ID == aliasQAT {
			t.Fatalf("desired build %q leaked into the OpenRouter feed", aliasQAT)
		}
		if m.ID == "gemma-4-26b" {
			sawAlias = true
		}
	}
	if !sawAlias {
		t.Fatalf("alias gemma-4-26b missing from OpenRouter feed: %+v", resp.Data)
	}
}
