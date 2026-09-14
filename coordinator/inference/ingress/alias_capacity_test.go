package ingress

import (
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAliasCapacityFallbackUsesPreviousWhenDesiredFull(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := newTestController(testServices{registry: reg, store: st, logger: logger, firstContentDeadlineBase: 5 * time.Second})

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	publishTestModels(t, reg, st)

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
	fallback, _, _, _, _, _, switched := srv.maybeFallbackAlias(parsed, aliasFallbackCapacity, "gemma-4-26b", aliasQAT, 10, 128, 0, registry.RequestTraits{}, false, nil)
	if !switched || fallback != aliasFP8 {
		t.Fatalf("fallback = %q switched=%v, want previous %q", fallback, switched, aliasFP8)
	}
	if parsed["model"] != aliasFP8 {
		t.Fatalf("parsed model = %q, want fallback build", parsed["model"])
	}
}
