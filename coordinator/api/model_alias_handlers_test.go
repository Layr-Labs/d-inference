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

func seedActiveModel(t *testing.T, st store.Store, modelID, displayName string) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: displayName, Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 8192, MinRAMGB: 24,
		Capabilities: []string{"chat"}, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}
}

// Admin can create a public alias over two builds; the alias becomes routable
// and /v1/models shows the alias while hiding the raw builds by default.
func TestModelAliasCreateAndListing(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	seedActiveModel(t, st, fp8, "Gemma 4 26B (fp8)")
	seedActiveModel(t, st, qat, "Gemma 4 26B (qat-4bit)")
	srv.SyncModelCatalog()

	// Create the alias: fp8 draining (weight 30), qat ramping (weight 70).
	body, _ := json.Marshal(map[string]any{
		"alias_id":     "gemma-4-26b",
		"display_name": "Gemma 4 26B",
		"builds": []map[string]any{
			{"build_id": fp8, "weight": 30},
			{"build_id": qat, "weight": 70},
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("create alias status = %d body = %s", rec.Code, rec.Body.String())
	}

	// The registry now resolves the alias to a concrete build.
	if !reg.IsAlias("gemma-4-26b") {
		t.Fatal("registry did not learn the alias after sync")
	}
	build, isAlias, ok := reg.ResolveModel("gemma-4-26b")
	if !isAlias || !ok || (build != fp8 && build != qat) {
		t.Fatalf("resolve = %q isAlias=%v ok=%v", build, isAlias, ok)
	}

	// /v1/models shows the alias and hides the raw builds. Call the handler
	// directly to bypass requireAuth (same pattern as the OpenRouter list test).
	listReq := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	listRec := httptest.NewRecorder()
	srv.handleListModels(listRec, listReq)
	if listRec.Code != http.StatusOK {
		t.Fatalf("list status = %d", listRec.Code)
	}
	var resp struct {
		Data []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"data"`
	}
	if err := json.Unmarshal(listRec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	var aliasName string
	for _, m := range resp.Data {
		if m.ID == "gemma-4-26b" {
			aliasName = m.Name
		}
	}
	if aliasName != "Gemma 4 26B" {
		t.Fatalf("alias not listed with display name: data=%+v", resp.Data)
	}
}

// aliasModelEntries returns the alias entry and the set of builds it covers
// (which the listing hides by default). Exercised directly so we don't need a
// live WebSocket provider just to populate registry.ListModels().
func TestAliasModelEntriesHidesBuilds(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	seedActiveModel(t, st, fp8, "Gemma 4 26B (fp8)")
	seedActiveModel(t, st, qat, "Gemma 4 26B (qat-4bit)")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		Builds: []store.ModelAliasBuild{
			{BuildID: fp8, Weight: 30, Active: true},
			{BuildID: qat, Weight: 70, Active: true},
		},
	}); err != nil {
		t.Fatal(err)
	}

	_, registryByID, err := srv.activeCatalogLookups()
	if err != nil {
		t.Fatal(err)
	}
	catalogByID := map[string]store.SupportedModel{fp8: {ID: fp8, Active: true, ModelType: "text"}, qat: {ID: qat, Active: true, ModelType: "text"}}
	capByModel := map[string]*registry.ModelCapacity{
		fp8: {ModelID: fp8, RoutableProviders: 2, WarmProviders: 1, CanAccept: true},
		qat: {ModelID: qat, RoutableProviders: 1, WarmProviders: 0, CanAccept: false},
	}

	entries, hidden := srv.aliasModelEntries(capByModel, catalogByID, registryByID)
	if len(entries) != 1 || entries[0].ID != "gemma-4-26b" {
		t.Fatalf("expected one alias entry, got %+v", entries)
	}
	// Capacity aggregates across both builds.
	if entries[0].Metadata.RoutableProviders != 3 || !entries[0].Metadata.CanAccept {
		t.Fatalf("alias capacity not aggregated: %+v", entries[0].Metadata)
	}
	if _, ok := hidden[fp8]; !ok {
		t.Fatalf("fp8 build should be hidden: %v", hidden)
	}
	if _, ok := hidden[qat]; !ok {
		t.Fatalf("qat build should be hidden: %v", hidden)
	}
}

// An alias whose builds are all drained (weight 0) resolves to nothing, so it
// must not be advertised in /v1/models (it would 503).
func TestAliasModelEntriesSkipsAllDrained(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	const fp8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const qat = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	seedActiveModel(t, st, fp8, "fp8")
	seedActiveModel(t, st, qat, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		Builds: []store.ModelAliasBuild{
			{BuildID: fp8, Weight: 0, Active: true},
			{BuildID: qat, Weight: 0, Active: true},
		},
	}); err != nil {
		t.Fatal(err)
	}

	_, registryByID, err := srv.activeCatalogLookups()
	if err != nil {
		t.Fatal(err)
	}
	catalogByID := map[string]store.SupportedModel{
		fp8: {ID: fp8, Active: true, ModelType: "text"},
		qat: {ID: qat, Active: true, ModelType: "text"},
	}
	entries, hidden := srv.aliasModelEntries(map[string]*registry.ModelCapacity{}, catalogByID, registryByID)
	if len(entries) != 0 {
		t.Fatalf("fully-drained alias must not be listed, got %+v", entries)
	}
	if len(hidden) != 0 {
		t.Fatalf("a skipped alias must not hide its builds, got %v", hidden)
	}
}

// Alias upsert rejects builds that don't reference a registered model and
// self-references, and delete removes the alias.
func TestModelAliasValidationAndDelete(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const real = "mlx-community/gemma-4-26b-a4b-it-fp8"
	seedActiveModel(t, st, real, "Gemma 4 26B (fp8)")
	srv.SyncModelCatalog()

	post := func(body map[string]any) int {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec.Code
	}

	// Phantom build → 400.
	if code := post(map[string]any{"alias_id": "g", "builds": []map[string]any{{"build_id": "does/not-exist", "weight": 1}}}); code != http.StatusBadRequest {
		t.Fatalf("phantom build status = %d, want 400", code)
	}
	// Self-reference → 400.
	if code := post(map[string]any{"alias_id": "g", "builds": []map[string]any{{"build_id": "g", "weight": 1}}}); code != http.StatusBadRequest {
		t.Fatalf("self-ref status = %d, want 400", code)
	}
	// Missing builds → 400.
	if code := post(map[string]any{"alias_id": "g"}); code != http.StatusBadRequest {
		t.Fatalf("no-builds status = %d, want 400", code)
	}
	// Valid → 200.
	if code := post(map[string]any{"alias_id": "gemma-4-26b", "builds": []map[string]any{{"build_id": real, "weight": 100}}}); code != http.StatusOK {
		t.Fatalf("valid alias status = %d, want 200", code)
	}
	if !reg.IsAlias("gemma-4-26b") {
		t.Fatal("alias not active after create")
	}

	// Delete it.
	del := httptest.NewRequest(http.MethodDelete, "/v1/admin/models/aliases/gemma-4-26b", nil)
	del.Header.Set("Authorization", "Bearer publish-secret")
	delRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(delRec, del)
	if delRec.Code != http.StatusOK {
		t.Fatalf("delete status = %d body=%s", delRec.Code, delRec.Body.String())
	}
	if reg.IsAlias("gemma-4-26b") {
		t.Fatal("alias still active after delete")
	}
}

// Unauthenticated alias writes are rejected.
func TestModelAliasRequiresAuth(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader([]byte(`{"alias_id":"x","builds":[]}`)))
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Fatalf("unauthenticated alias write should be rejected, got %d", rec.Code)
	}
}
