package catalog

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The feed is catalog-driven: an active model stays listed even when NO provider
// is currently online for it (transient capacity is OpenRouter's concern via
// 429s, not a reason to delist). Datacenters are empty in that case.
func TestOpenRouterFeedSurvivesProviderOutage(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTestController(reg, st, logger)

	const modelID = "mlx-community/orphan-model"
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: "Orphan", Quantization: "4bit",
		MaxContextLength: 8192, MaxOutputLength: 2048, MinRAMGB: 8, Status: "active",
		Capabilities: []string{"tools"},
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: ModelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}
	srv.Invalidate()
	// Note: NO provider connected. registry.ListModels() is empty.

	rec := httptest.NewRecorder()
	srv.ListOpenRouterModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
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

// Public aliases get the /v1/models treatment in the OpenRouter feed too: the
// alias is the purchasable entry, member builds are hidden, and the marketplace
// never sees a raw quant build that a migration will later retire.
func TestOpenRouterModelsAliasEntriesHideBuilds(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := newTestController(reg, st, logger)

	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B fp8")
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B qat")
	const aliasHuggingFaceID = "google/gemma-4-26b-it"
	primaryRecord, err := st.GetModelRegistryRecord(aliasQAT)
	if err != nil {
		t.Fatal(err)
	}
	primaryEntry := registryEntryFromRecord(primaryRecord)
	primaryEntry.Metadata = map[string]any{huggingFaceIDMetadataKey: aliasHuggingFaceID}
	if err := st.UpsertModelRegistryEntry(primaryEntry); err != nil {
		t.Fatal(err)
	}
	seedActiveModel(t, st, "mlx-community/unrelated-9b", "Unrelated 9B")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.Invalidate()

	rec := httptest.NewRecorder()
	srv.ListOpenRouterModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
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
	if alias.HuggingFaceID != aliasHuggingFaceID {
		t.Fatalf("alias hugging_face_id = %q, want %q", alias.HuggingFaceID, aliasHuggingFaceID)
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
	srv := newTestController(registry.New(logger), st, logger)

	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B fp8")
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, RetiredBuilds: []string{aliasFP8},
	}); err != nil {
		t.Fatal(err)
	}
	srv.Invalidate()

	rec := httptest.NewRecorder()
	srv.ListOpenRouterModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
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

func TestConcreteModelEligibleForOpenRouterFeed(t *testing.T) {
	const modelID = "model"
	catalog := map[string]store.SupportedModel{
		modelID: {ID: modelID, ModelType: "text", Active: true},
	}
	if !concreteModelEligibleForOpenRouterFeed(modelID, catalog, nil) {
		t.Fatal("text catalog model without providers should be feed-eligible")
	}
	if concreteModelEligibleForOpenRouterFeed(modelID, catalog, map[string]string{modelID: "embedding"}) {
		t.Fatal("provider-reported non-text model should not be feed-eligible")
	}
	if concreteModelEligibleForOpenRouterFeed("missing", catalog, nil) {
		t.Fatal("missing catalog model should not be feed-eligible")
	}
}
