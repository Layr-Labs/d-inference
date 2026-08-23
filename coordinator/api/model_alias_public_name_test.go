package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The headline guarantee at the function level: the consumer-facing model name
// is the alias, and the concrete build is never substituted in.
func TestConsumerModelAndChunkRewriteNeverLeakBuild(t *testing.T) {
	const build = aliasQAT
	const alias = "gemma-4-26b"

	pr := &registry.PendingRequest{Model: build, PublicModel: alias}
	if got := consumerModel(pr); got != alias {
		t.Fatalf("consumerModel = %q, want alias %q", got, alias)
	}
	compact := `data: {"id":"x","model":"` + build + `","choices":[]}`
	spaced := `data: {"id":"x","model": "` + build + `","choices":[]}`
	if out := rewriteChunkModel(compact, pr); strings.Contains(out, build) || !strings.Contains(out, alias) {
		t.Fatalf("compact chunk still leaks build: %q", out)
	}
	if out := rewriteChunkModel(spaced, pr); strings.Contains(out, build) || !strings.Contains(out, alias) {
		t.Fatalf("spaced chunk still leaks build: %q", out)
	}

	raw := &registry.PendingRequest{Model: build, PublicModel: build}
	if got := consumerModel(raw); got != build {
		t.Fatalf("raw consumerModel = %q, want %q", got, build)
	}
	if out := rewriteChunkModel(compact, raw); out != compact {
		t.Fatalf("raw-id chunk should be unchanged, got %q", out)
	}
	none := &registry.PendingRequest{Model: build}
	if got := consumerModel(none); got != build {
		t.Fatalf("empty PublicModel should fall back to build, got %q", got)
	}
}

// After full retirement (previous_build cleared, the old build moved into the
// retired lineage but still a registered/active model), /v1/models must STILL
// show only the alias — never the raw retired quant. Regression for the
// retired-build listing leak: a consumer must only ever see the alias.
func TestListModelsHidesRetiredAliasBuild(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B (fp8)")
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B (qat-4bit)")
	// Fully retired: desired=qat, previous cleared, fp8 in the retired lineage
	// (still registered + active in the catalog — the exact leak condition).
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, RetiredBuilds: []string{aliasFP8},
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	rec := httptest.NewRecorder()
	srv.handleListModels(rec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	sawAlias, leakedFP8, leakedQAT := false, false, false
	for _, m := range resp.Data {
		switch m.ID {
		case "gemma-4-26b":
			sawAlias = true
		case aliasFP8:
			leakedFP8 = true
		case aliasQAT:
			leakedQAT = true
		}
	}
	if !sawAlias {
		t.Fatalf("alias gemma-4-26b missing from /v1/models: %+v", resp.Data)
	}
	if leakedFP8 {
		t.Fatalf("retired build %q leaked into /v1/models — consumers must only ever see the alias", aliasFP8)
	}
	if leakedQAT {
		t.Fatalf("desired build %q leaked into /v1/models", aliasQAT)
	}

	// The hidden set covers the retired build directly too.
	_, registryByID, err := srv.activeCatalogLookups()
	if err != nil {
		t.Fatal(err)
	}
	catalogByID := map[string]store.SupportedModel{aliasFP8: {ID: aliasFP8, Active: true, ModelType: "text"}, aliasQAT: {ID: aliasQAT, Active: true, ModelType: "text"}}
	_, hidden := srv.aliasModelEntries(map[string]*registry.ModelCapacity{}, catalogByID, registryByID)
	if _, ok := hidden[aliasFP8]; !ok {
		t.Fatalf("retired build should be in the hidden set: %v", hidden)
	}
}
