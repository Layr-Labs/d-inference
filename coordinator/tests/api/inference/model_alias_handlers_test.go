package inference_test

import (
	"log/slog"
	"os"
	"testing"

	routeplan "github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func seedActiveModel(t *testing.T, st store.Store, modelID, displayName string) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: displayName, Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 8192, MinRAMGB: 24,
		Capabilities: []string{"chat"}, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: modelID, Version: "v1", R2Prefix: testModelPrefix(modelID, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}
}

const (
	aliasFP8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	aliasQAT = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
)

func TestAliasCapacityFallbackUsesPreviousWhenDesiredFull(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.server.SyncModelCatalog()

	registerBuildsProvider(srv, "p-prev", aliasFP8)
	registerBuildsProvider(srv, "p-desired", aliasQAT)
	p := reg.GetProvider("p-desired")
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1_000
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1_000
	p.Mu().Unlock()

	if candidates, rejections, _ := reg.QuickCapacityCheck(aliasQAT, 10, 128, registry.RequestTraits{}); candidates != 0 || rejections != 1 {
		t.Fatalf("desired capacity = candidates %d rejections %d, want 0/1", candidates, rejections)
	}
	if candidates, rejections, _ := reg.QuickCapacityCheck(aliasFP8, 10, 128, registry.RequestTraits{}); candidates != 1 || rejections != 0 {
		t.Fatalf("previous capacity = candidates %d rejections %d, want 1/0", candidates, rejections)
	}

	parsed := map[string]any{
		"model":    aliasQAT,
		"messages": []any{map[string]any{"role": "user", "content": "hi"}},
	}
	fallback, _, _, _, _, _, switched := srv.NewAliasPlanner().Fallback(parsed, routeplan.FallbackCapacity, "gemma-4-26b", aliasQAT, 10, 128, 0, registry.RequestTraits{}, false, nil)
	if !switched || fallback != aliasFP8 {
		t.Fatalf("fallback = %q switched=%v, want previous %q", fallback, switched, aliasFP8)
	}
	if parsed["model"] != aliasFP8 {
		t.Fatalf("parsed model = %q, want fallback build", parsed["model"])
	}
}
