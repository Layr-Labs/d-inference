package api

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"

	"strconv"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
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

const (
	aliasFP8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	aliasQAT = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
)

// Admin can create a public alias pointing at a desired build (+ previous); the
// alias becomes routable and /v1/models shows the alias while hiding the raw
// builds by default.
func TestModelAliasCreateAndListing(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B (fp8)")
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B (qat-4bit)")
	seedActiveModel(t, st, "gemma-4-26b-retired", "Gemma 4 26B (retired)")
	srv.SyncModelCatalog()

	// Create the alias: desired = qat, previous = fp8.
	body, _ := json.Marshal(map[string]any{
		"alias_id":       "gemma-4-26b",
		"display_name":   "Gemma 4 26B",
		"desired_build":  aliasQAT,
		"previous_build": aliasFP8,
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("create alias status = %d body = %s", rec.Code, rec.Body.String())
	}

	// The registry resolves the alias; with no providers it queues against desired.
	if !reg.IsAlias("gemma-4-26b") {
		t.Fatal("registry did not learn the alias after sync")
	}
	build, isAlias, ok := reg.ResolveModel("gemma-4-26b")
	if !isAlias || !ok || build != aliasQAT {
		t.Fatalf("resolve = %q isAlias=%v ok=%v, want desired qat", build, isAlias, ok)
	}

	// /v1/models shows the alias and hides the raw builds.
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
	leaked := false
	for _, m := range resp.Data {
		if m.ID == "gemma-4-26b" {
			aliasName = m.Name
		}
		if m.ID == aliasFP8 || m.ID == aliasQAT {
			leaked = true
		}
	}
	if aliasName != "Gemma 4 26B" {
		t.Fatalf("alias not listed with display name: data=%+v", resp.Data)
	}
	if leaked {
		t.Fatalf("raw builds should be hidden behind the alias: data=%+v", resp.Data)
	}
}

// aliasModelEntries returns the alias entry and the set of builds it covers,
// hiding retired lineage while aggregating active capacity from desired + previous.
func TestAliasModelEntriesHidesBuilds(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B (fp8)")
	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B (qat-4bit)")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8, RetiredBuilds: []string{"gemma-4-26b-retired"},
	}); err != nil {
		t.Fatal(err)
	}

	_, registryByID, err := srv.activeCatalogLookups()
	if err != nil {
		t.Fatal(err)
	}
	catalogByID := map[string]store.SupportedModel{
		aliasFP8:              {ID: aliasFP8, Active: true, ModelType: "text"},
		aliasQAT:              {ID: aliasQAT, Active: true, ModelType: "text"},
		"gemma-4-26b-retired": {ID: "gemma-4-26b-retired", Active: true, ModelType: "text"},
	}
	capByModel := map[string]*registry.ModelCapacity{
		aliasQAT:              {ModelID: aliasQAT, RoutableProviders: 2, WarmProviders: 1, CanAccept: true},
		aliasFP8:              {ModelID: aliasFP8, RoutableProviders: 1, WarmProviders: 0, CanAccept: false},
		"gemma-4-26b-retired": {ModelID: "gemma-4-26b-retired", RoutableProviders: 10, WarmProviders: 10, CanAccept: true},
	}

	entries, hidden := srv.aliasModelEntries(capByModel, catalogByID, registryByID)
	if len(entries) != 1 || entries[0].ID != "gemma-4-26b" {
		t.Fatalf("expected one alias entry, got %+v", entries)
	}
	if entries[0].HuggingFaceID != aliasQAT {
		t.Fatalf("alias hugging_face_id = %q, want primary build %q", entries[0].HuggingFaceID, aliasQAT)
	}
	// Capacity aggregates across desired + previous only (2 + 1 = 3 routable);
	// retired builds are hide-only and must not count as active alias capacity.
	if entries[0].Metadata.RoutableProviders != 3 || entries[0].Metadata.WarmProviders != 1 || !entries[0].Metadata.CanAccept {
		t.Fatalf("alias capacity not aggregated: %+v", entries[0].Metadata)
	}
	if _, ok := hidden[aliasFP8]; !ok {
		t.Fatalf("fp8 (previous) build should be hidden: %v", hidden)
	}
	if _, ok := hidden[aliasQAT]; !ok {
		t.Fatalf("qat (desired) build should be hidden: %v", hidden)
	}
	if _, ok := hidden["gemma-4-26b-retired"]; !ok {
		t.Fatalf("retired build should be hidden without counting capacity: %v", hidden)
	}
}

// An alias whose desired build isn't in the catalog yet falls back to the
// previous build for its primary metadata; an alias with no in-catalog build is
// not advertised.
func TestAliasModelEntriesDesiredNotInCatalog(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "fp8 only")
	// Only fp8 (previous) is in the catalog; qat (desired) isn't registered yet.
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	// An alias whose desired build is empty / has no in-catalog build is skipped.
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "ghost", DisplayName: "Ghost", Active: true,
		DesiredBuild: "mlx-community/not-registered",
	}); err != nil {
		t.Fatal(err)
	}

	_, registryByID, err := srv.activeCatalogLookups()
	if err != nil {
		t.Fatal(err)
	}
	catalogByID := map[string]store.SupportedModel{aliasFP8: {ID: aliasFP8, Active: true, ModelType: "text"}}
	entries, hidden := srv.aliasModelEntries(map[string]*registry.ModelCapacity{}, catalogByID, registryByID)
	if len(entries) != 1 || entries[0].ID != "gemma-4-26b" {
		t.Fatalf("only the alias with an in-catalog build should list, got %+v", entries)
	}
	if _, ok := hidden[aliasFP8]; !ok {
		t.Fatalf("previous build should still be hidden, got %v", hidden)
	}
	if _, ok := hidden["mlx-community/not-registered"]; ok {
		t.Fatalf("a skipped alias must not hide its build, got %v", hidden)
	}
}

// Routing through aliasModelEntries / ResolveModel: when only the previous build
// has routable providers the alias resolves to previous; once desired is routable
// it resolves to desired.
func TestAliasRoutingDesiredAndPrevious(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	// Only the previous build is routable → resolve to previous.
	registerBuildsProvider(srv, "p-prev", aliasFP8)
	for i := 0; i < 50; i++ {
		if b, _, ok := reg.ResolveModel("gemma-4-26b"); !ok || b != aliasFP8 {
			t.Fatalf("should route to previous fp8, got %q ok=%v", b, ok)
		}
	}

	// Now the desired build becomes routable → resolve to desired.
	registerBuildsProvider(srv, "p-desired", aliasQAT)
	for i := 0; i < 50; i++ {
		if b, _, ok := reg.ResolveModel("gemma-4-26b"); !ok || b != aliasQAT {
			t.Fatalf("should route to desired qat once routable, got %q ok=%v", b, ok)
		}
	}
}

func TestAliasCapacityFallbackUsesPreviousWhenDesiredFull(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

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

// Alias upsert rejects unregistered builds, self-references, and a missing
// desired build; a revert is just re-PUT with desired set back.
func TestModelAliasValidationAndRevert(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	srv.SyncModelCatalog()

	post := func(body map[string]any) int {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec.Code
	}

	// Phantom desired build → 400.
	if code := post(map[string]any{"alias_id": "g", "desired_build": "does/not-exist"}); code != http.StatusBadRequest {
		t.Fatalf("phantom build status = %d, want 400", code)
	}
	// Phantom previous build → 400.
	if code := post(map[string]any{"alias_id": "g", "desired_build": aliasQAT, "previous_build": "does/not-exist"}); code != http.StatusBadRequest {
		t.Fatalf("phantom previous status = %d, want 400", code)
	}
	// Self-reference → 400.
	if code := post(map[string]any{"alias_id": "g", "desired_build": "g"}); code != http.StatusBadRequest {
		t.Fatalf("self-ref status = %d, want 400", code)
	}
	// Missing desired_build → 400.
	if code := post(map[string]any{"alias_id": "g"}); code != http.StatusBadRequest {
		t.Fatalf("no-desired status = %d, want 400", code)
	}
	// Valid rollout: desired = qat, previous = fp8 → 200.
	if code := post(map[string]any{"alias_id": "gemma-4-26b", "desired_build": aliasQAT, "previous_build": aliasFP8}); code != http.StatusOK {
		t.Fatalf("valid alias status = %d, want 200", code)
	}
	if b, _, _ := reg.ResolveModel("gemma-4-26b"); b != aliasQAT {
		t.Fatalf("after rollout resolve = %q, want qat", b)
	}

	// Revert: re-PUT with desired back to fp8, no previous → 200.
	if code := post(map[string]any{"alias_id": "gemma-4-26b", "desired_build": aliasFP8}); code != http.StatusOK {
		t.Fatalf("revert status = %d, want 200", code)
	}
	saved, _, _ := st.GetModelAlias("gemma-4-26b")
	if saved.DesiredBuild != aliasFP8 || saved.PreviousBuild != "" {
		t.Fatalf("revert not persisted: desired=%q previous=%q", saved.DesiredBuild, saved.PreviousBuild)
	}
	if b, _, _ := reg.ResolveModel("gemma-4-26b"); b != aliasFP8 {
		t.Fatalf("after revert resolve = %q, want fp8", b)
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
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader([]byte(`{"alias_id":"x","desired_build":"y"}`)))
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Fatalf("unauthenticated alias write should be rejected, got %d", rec.Code)
	}
}

// A provider that connects over the real WebSocket path and advertises a build
// under an existing alias is pushed desired_models right after register.
func TestProviderReceivesDesiredModelsAfterRegister(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour // don't race the desired_models read with a challenge
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	// Alias exists BEFORE the provider connects: desired = qat, previous = fp8.
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Provider advertises the previous build (fp8) and runs a feature-version
	// Swift binary, so it qualifies for desired_models.
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: aliasFP8, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		Version:                 minProviderVersionForDesiredModels,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Read until we see desired_models (other messages like trust_status may
	// arrive first).
	deadline := time.Now().Add(4 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatal("did not receive desired_models after register")
		}
		readCtx, readCancel := context.WithTimeout(ctx, 2*time.Second)
		_, data, rerr := conn.Read(readCtx)
		readCancel()
		if rerr != nil {
			t.Fatalf("read: %v", rerr)
		}
		var env struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &env); err != nil {
			continue
		}
		if env.Type != protocol.TypeDesiredModels {
			continue
		}
		var msg protocol.DesiredModelsMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			t.Fatalf("decode desired_models: %v", err)
		}
		if len(msg.Models) != 1 {
			t.Fatalf("desired_models entries = %d, want 1: %+v", len(msg.Models), msg.Models)
		}
		e := msg.Models[0]
		if e.ModelName != "gemma-4-26b" || e.DesiredBuild != aliasQAT || e.PreviousBuild != aliasFP8 {
			t.Fatalf("desired_models entry mismatch: %+v", e)
		}
		return
	}
}

// Flipping an alias's desired build via the admin upsert endpoint fans out a
// fresh desired_models to every connected provider already serving the alias.
// This is the only test that drives the live fan-out path (handleModelAliasUpsert
// -> fanOutDesiredModels) with a CONNECTED provider over the real WebSocket. The
// concurrent registry write-lock pressure (the SetModelCatalog goroutine) plus
// the -race detector exercise the lock discipline fanOutDesiredModels relies on:
// it must NOT nest r.mu.RLock (it collects eligible IDs inside ForEachProvider,
// which holds r.mu.RLock, then calls DesiredModelsForProvider — which re-takes
// r.mu — only AFTER the outer lock is released). Nesting those RLocks risks a
// deadlock once a writer queues between them; the 5s upsert deadline guards it.
func TestAliasUpsertFansOutDesiredModelsToConnectedProvider(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour // don't race the desired_models read with a challenge
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	// Alias initially points entirely at fp8 (no rollout in flight). The provider
	// advertises fp8, so it is a member of the alias and qualifies for fan-out.
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: aliasFP8, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		Version:                 minProviderVersionForDesiredModels,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Drain the initial post-register desired_models (desired=fp8, no previous).
	readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
		return len(msg.Models) == 1 && msg.Models[0].DesiredBuild == aliasFP8 && msg.Models[0].PreviousBuild == ""
	}, "initial desired_models (fp8)")

	// Now flip the rollout: desired=qat, previous=fp8, via the admin endpoint.
	// This must fan out a fresh desired_models to the connected provider without
	// the handler deadlocking.
	body, _ := json.Marshal(map[string]any{
		"alias_id":       "gemma-4-26b",
		"display_name":   "Gemma 4 26B",
		"desired_build":  aliasQAT,
		"previous_build": aliasFP8,
	})

	// Apply write-lock pressure to the registry while the fan-out runs. The old
	// fanOutDesiredModels nested r.mu.RLock (outer ForEachProvider + inner
	// DesiredModelsForProvider). A pending writer (Go's RWMutex blocks new
	// readers once a writer waits) wedged between the two RLocks deadlocks the
	// handler. A constant stream of SetModelCatalog writers makes that window
	// reliably hit, turning the latent hazard into a deterministic failure.
	stopWriters := make(chan struct{})
	writersDone := make(chan struct{})
	go func() {
		defer close(writersDone)
		for {
			select {
			case <-stopWriters:
				return
			default:
				reg.SetModelCatalog([]registry.CatalogEntry{{ID: aliasFP8}, {ID: aliasQAT}})
			}
		}
	}()

	upsertDone := make(chan int, 1)
	go func() {
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		upsertDone <- rec.Code
	}()
	select {
	case code := <-upsertDone:
		close(stopWriters)
		<-writersDone
		if code != http.StatusOK {
			t.Fatalf("alias upsert status = %d", code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("alias upsert hung — fanOutDesiredModels likely deadlocked on a nested registry RLock")
	}

	// The provider receives the new rollout target over the live connection.
	readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
		return len(msg.Models) == 1 &&
			msg.Models[0].ModelName == "gemma-4-26b" &&
			msg.Models[0].DesiredBuild == aliasQAT &&
			msg.Models[0].PreviousBuild == aliasFP8
	}, "post-flip desired_models (qat/fp8)")
}

// readDesiredModels reads frames from conn until a desired_models message
// satisfies match, or fails the test on timeout. Non-desired_models frames
// (trust_status, etc.) are skipped.
func readDesiredModels(
	ctx context.Context,
	t *testing.T,
	conn *websocket.Conn,
	match func(protocol.DesiredModelsMessage) bool,
	what string,
) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatalf("did not receive %s", what)
		}
		readCtx, readCancel := context.WithTimeout(ctx, 2*time.Second)
		_, data, rerr := conn.Read(readCtx)
		readCancel()
		if rerr != nil {
			t.Fatalf("read %s: %v", what, rerr)
		}
		var env struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &env); err != nil || env.Type != protocol.TypeDesiredModels {
			continue
		}
		var msg protocol.DesiredModelsMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			t.Fatalf("decode %s: %v", what, err)
		}
		if match(msg) {
			return
		}
		// A desired_models that doesn't match yet (e.g. stale) — keep reading.
	}
}

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

func TestHandleUsageUsesRecordedPublicModelOnly(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	reg.SetModelAliases(map[string]registry.AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT},
	})
	st.RecordUsageFullWithPublicModel("p1", "acct-1", "", aliasFP8, "gemma-4-26b", "req-alias", 10, 5, 100, nil)
	st.RecordUsageFull("p2", "acct-1", "", aliasQAT, "req-raw", 3, 2, 50, nil)

	req := httptest.NewRequest(http.MethodGet, "/v1/payments/usage", nil)
	req = req.WithContext(context.WithValue(req.Context(), ctxKeyConsumer, "acct-1"))
	rec := httptest.NewRecorder()
	srv.handleUsage(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Usage []struct {
			JobID string `json:"job_id"`
			Model string `json:"model"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode usage: %v", err)
	}
	got := map[string]string{}
	for _, u := range resp.Usage {
		got[u.JobID] = u.Model
	}
	if got["req-alias"] != "gemma-4-26b" {
		t.Fatalf("alias usage model = %q, want public alias", got["req-alias"])
	}
	if got["req-raw"] != aliasQAT {
		t.Fatalf("raw usage model = %q, want concrete build", got["req-raw"])
	}
}

// alias_id is spliced into consumer-visible JSON (SSE chunk rewriting) and the
// DELETE URL path; JSON-special or multi-segment ids must be rejected at the
// door. Regression for the security review's alias-charset finding.
func TestAliasIDCharsetValidation(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	seedActiveModel(t, st, aliasQAT, "qat")
	srv.SyncModelCatalog()

	post := func(aliasID string) int {
		b, _ := json.Marshal(map[string]any{"alias_id": aliasID, "desired_build": aliasQAT})
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec.Code
	}

	for _, bad := range []string{
		`gemma"4`,                               // double quote — would corrupt rewritten SSE chunk JSON
		`gemma\4`,                               // backslash — same
		"gemma/4-26b",                           // slash — multi-segment, undeletable via path param
		"gemma 4",                               // space
		"gemma\n4",                              // control char
		"..",                                    // traversal
		strings.Repeat("g", maxAliasIDLength+1), // too long
	} {
		if code := post(bad); code != http.StatusBadRequest {
			t.Fatalf("alias_id %q accepted with status %d, want 400", bad, code)
		}
	}
	for _, good := range []string{"gemma-4-26b", "gpt-oss_120b.v2", "G4"} {
		if code := post(good); code != http.StatusOK {
			t.Fatalf("alias_id %q rejected with status %d, want 200", good, code)
		}
	}
}

// retiredBuildsAfterUpsert keeps the alias lineage: rotated-out members are
// retained (bounded), re-promoted members leave the list.
func TestRetiredBuildsAfterUpsert(t *testing.T) {
	// No prior alias → no lineage.
	if got := retiredBuildsAfterUpsert(nil, "b2", ""); got != nil {
		t.Fatalf("no prior should yield nil, got %v", got)
	}
	// Rotation: desired b1→b2 (previous b1) retires nothing (b1 still a member);
	// then b2→b3 with previous cleared retires both b2 and b1.
	step1 := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "b1"}, "b2", "b1")
	if len(step1) != 0 {
		t.Fatalf("members must not be retired, got %v", step1)
	}
	step2 := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "b2", PreviousBuild: "b1"}, "b3", "")
	if len(step2) != 2 || step2[0] != "b2" || step2[1] != "b1" {
		t.Fatalf("rotated-out members should be retired, got %v", step2)
	}
	// Re-promotion: b1 comes back as desired → leaves the lineage.
	step3 := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "b3", RetiredBuilds: []string{"b2", "b1"}}, "b1", "")
	if len(step3) != 2 || step3[0] != "b2" || step3[1] != "b3" {
		t.Fatalf("re-promoted build must leave lineage and old desired must join, got %v", step3)
	}
	// Bound: the oldest entries are dropped first.
	var many []string
	for i := 0; i < maxRetiredBuilds+4; i++ {
		many = append(many, "old-"+strconv.Itoa(i))
	}
	bounded := retiredBuildsAfterUpsert(&store.ModelAlias{DesiredBuild: "bX", RetiredBuilds: many}, "bY", "")
	if len(bounded) != maxRetiredBuilds {
		t.Fatalf("lineage should be bounded to %d, got %d", maxRetiredBuilds, len(bounded))
	}
	if bounded[0] == "old-0" {
		t.Fatal("oldest entry should be dropped first")
	}
}

// The HTTP upsert path persists lineage: finishing a rollout (previous cleared)
// moves the old build into retired_builds, and the registry gate then matches a
// returning provider that only advertises the retired build.
func TestAliasUpsertRecordsRetiredLineage(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	srv.SyncModelCatalog()

	post := func(body map[string]any) int {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec.Code
	}

	// Rollout: desired=qat, previous=fp8. Then Step 7: clear previous.
	if code := post(map[string]any{"alias_id": "gemma-4-26b", "desired_build": aliasQAT, "previous_build": aliasFP8}); code != http.StatusOK {
		t.Fatalf("rollout upsert = %d", code)
	}
	if code := post(map[string]any{"alias_id": "gemma-4-26b", "desired_build": aliasQAT}); code != http.StatusOK {
		t.Fatalf("retirement upsert = %d", code)
	}
	saved, _, _ := st.GetModelAlias("gemma-4-26b")
	if len(saved.RetiredBuilds) != 1 || saved.RetiredBuilds[0] != aliasFP8 {
		t.Fatalf("fp8 should be in retired lineage, got %v", saved.RetiredBuilds)
	}

	// The registry gate sees the lineage: a provider advertising only fp8
	// (offline through the retirement) is still told to converge to qat.
	reg.Register("p-returning", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: aliasFP8, ModelType: "gemma"}},
		Backend:  registry.BackendMLXSwift,
		Version:  minProviderVersionForDesiredModels,
	})
	entries := reg.DesiredModelsForProvider("p-returning")
	if len(entries) != 1 || entries[0].DesiredBuild != aliasQAT {
		t.Fatalf("returning provider should be told qat via lineage, got %+v", entries)
	}
}

// Deleting an alias fans the post-delete desired state out to the fleet. A
// provider whose ONLY desired entry came from the deleted alias must receive an
// EMPTY desired_models — that is what marks its in-flight prefetch stale.
func TestAliasDeleteFansOutEmptyDesiredModels(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: aliasFP8, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		Version:                 minProviderVersionForDesiredModels,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Initial post-register desired_models: the rollout entry.
	readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
		return len(msg.Models) == 1 && msg.Models[0].DesiredBuild == aliasQAT
	}, "initial desired_models (qat)")

	// Delete the alias via the admin endpoint.
	del := httptest.NewRequest(http.MethodDelete, "/v1/admin/models/aliases/gemma-4-26b", nil)
	del.Header.Set("Authorization", "Bearer publish-secret")
	delRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(delRec, del)
	if delRec.Code != http.StatusOK {
		t.Fatalf("delete status = %d body=%s", delRec.Code, delRec.Body.String())
	}

	// The provider's only desired entry came from the deleted alias → it must
	// receive an EMPTY desired_models (not silence).
	readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
		return len(msg.Models) == 0
	}, "post-delete empty desired_models")
}

// Registering a concrete model whose id collides with an existing public alias
// is rejected — the alias map would hijack raw-id requests for it (reverse of
// the alias upsert's namespace guard).
func TestRegisterModelRejectsAliasCollision(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	seedActiveModel(t, st, aliasQAT, "qat")
	srv.SyncModelCatalog()

	// Create the alias first.
	if err := st.UpsertModelAlias(&store.ModelAlias{AliasID: "gemma-4-26b", Active: true, DesiredBuild: aliasQAT}); err != nil {
		t.Fatal(err)
	}

	body, _ := json.Marshal(map[string]any{
		"model_id":           "gemma-4-26b", // collides with the alias
		"version":            "v1",
		"quantization":       "4bit",
		"max_context_length": 131072,
		"max_output_length":  8192,
		"min_ram_gb":         24,
		"input_price":        50000,
		"output_price":       200000,
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("register over alias status = %d, want 409 (body=%s)", rec.Code, rec.Body.String())
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

// TestModelAliasTakeoverOfConcreteID covers the 8-bit→4-bit public-name cutover:
// an alias adopts the live concrete id "gemma-4-26b", absorbing it as the
// previous/fallback build while pointing desired at the new 4-bit build. The
// critical safety property is that the absorbed model's catalog weight hash is
// untouched, so the providers already serving it are not untrusted.
func TestModelAliasTakeoverOfConcreteID(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const legacyID = "gemma-4-26b"       // live concrete build = today's public name
	const qatID = "gemma-4-26b-qat-4bit" // the new 4-bit build
	seedActiveModel(t, st, legacyID, "Gemma 4 26B (8-bit)")
	seedActiveModel(t, st, qatID, "Gemma 4 26B (qat-4bit)")
	srv.SyncModelCatalog()
	hashBefore := reg.CatalogWeightHash(legacyID)

	post := func(bodyMap map[string]any) *httptest.ResponseRecorder {
		body, _ := json.Marshal(bodyMap)
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	// Without takeover, adopting an existing concrete id is a 409.
	if rec := post(map[string]any{"alias_id": legacyID, "desired_build": qatID, "previous_build": legacyID}); rec.Code != http.StatusConflict {
		t.Fatalf("expected 409 without takeover, got %d: %s", rec.Code, rec.Body.String())
	}
	// Takeover requires previous_build == alias_id (fail-closed on the exact shape).
	if rec := post(map[string]any{"alias_id": legacyID, "desired_build": qatID, "takeover": true}); rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 when takeover lacks previous_build==alias_id, got %d: %s", rec.Code, rec.Body.String())
	}
	// desired_build may never equal the alias name even under takeover.
	if rec := post(map[string]any{"alias_id": legacyID, "desired_build": legacyID, "previous_build": legacyID, "takeover": true}); rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 when desired_build == alias_id, got %d: %s", rec.Code, rec.Body.String())
	}
	// Valid takeover.
	if rec := post(map[string]any{"alias_id": legacyID, "display_name": "Gemma 4 26B", "desired_build": qatID, "previous_build": legacyID, "takeover": true}); rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for valid takeover, got %d: %s", rec.Code, rec.Body.String())
	}

	// The public name now resolves through the alias to the 4-bit desired build.
	if b, isAlias, ok := reg.ResolveModel(legacyID); !isAlias || !ok || b != qatID {
		t.Fatalf("resolve after takeover = %q isAlias=%v ok=%v, want desired %q", b, isAlias, ok, qatID)
	}
	// CRITICAL: the absorbed model's catalog weight hash is unchanged, so the
	// fleet already serving the legacy build is NOT untrusted by the takeover.
	if after := reg.CatalogWeightHash(legacyID); after != hashBefore {
		t.Fatalf("takeover changed catalog hash for %s (%q -> %q) — would untrust the live fleet", legacyID, hashBefore, after)
	}
}

// An OpenRouter-only alias clones every model-list and dedicated-feed detail
// from a standard source alias while overriding its configured identities.

func TestOpenRouterAliasClonesSourceEntry(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B")
	srv.SyncModelCatalog()

	const (
		baseAlias = "gemma-4-26b"
		paidAlias = "gemma-4-26b-a4b-it"
		paidSlug  = "google/gemma-4-26b-it"
		paidHFID  = "google/gemma-4-26b-it"
	)
	post := func(path string, payload map[string]any) *httptest.ResponseRecorder {
		t.Helper()
		body, _ := json.Marshal(payload)
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}
	if rec := post("/v1/admin/models/aliases", map[string]any{
		"alias_id": baseAlias, "display_name": "Gemma 4 26B", "desired_build": aliasQAT,
	}); rec.Code != http.StatusOK {
		t.Fatalf("create source alias: status=%d body=%s", rec.Code, rec.Body.String())
	}
	if rec := post("/v1/admin/models/openrouter-aliases", map[string]any{
		"id": paidAlias, "source_model": baseAlias,
		"openrouter_slug": paidSlug, "hugging_face_id": paidHFID,
	}); rec.Code != http.StatusOK {
		t.Fatalf("create OpenRouter alias: status=%d body=%s", rec.Code, rec.Body.String())
	}

	saved, found, err := st.GetModelAlias(paidAlias)
	if err != nil || !found || !saved.OpenRouterOnly || saved.SourceModel != baseAlias || saved.OpenRouterSlug != paidSlug || saved.HuggingFaceID != paidHFID {
		t.Fatalf("stored OpenRouter alias = %+v found=%v err=%v", saved, found, err)
	}
	listAliasesReq := httptest.NewRequest(http.MethodGet, "/v1/admin/models/openrouter-aliases", nil)
	listAliasesReq.Header.Set("Authorization", "Bearer publish-secret")
	listAliasesRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(listAliasesRec, listAliasesReq)
	if listAliasesRec.Code != http.StatusOK {
		t.Fatalf("list OpenRouter aliases: status=%d body=%s", listAliasesRec.Code, listAliasesRec.Body.String())
	}
	var aliasList struct {
		Aliases []store.ModelAlias `json:"aliases"`
	}
	if err := json.Unmarshal(listAliasesRec.Body.Bytes(), &aliasList); err != nil || len(aliasList.Aliases) != 1 || aliasList.Aliases[0].AliasID != paidAlias {
		t.Fatalf("OpenRouter alias list = %+v err=%v", aliasList.Aliases, err)
	}

	// OpenRouter can call either id; both resolve to the source alias's live build.
	for _, alias := range []string{baseAlias, paidAlias} {
		build, isAlias, ok := reg.ResolveModel(alias)
		if !isAlias || !ok || build != aliasQAT {
			t.Fatalf("resolve(%s) = %q isAlias=%v ok=%v, want %q", alias, build, isAlias, ok, aliasQAT)
		}
	}
	if got := reg.PublicNameForBuild(aliasQAT); got != baseAlias {
		t.Fatalf("PublicNameForBuild = %q, want source alias %s", got, baseAlias)
	}

	// OpenRouter-only aliases remain callable but are not advertised in the
	// standard consumer catalog.
	listRec := httptest.NewRecorder()
	srv.handleListModels(listRec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if listRec.Code != http.StatusOK {
		t.Fatalf("list status = %d", listRec.Code)
	}
	var listResp types.ModelListResponse
	if err := json.Unmarshal(listRec.Body.Bytes(), &listResp); err != nil {
		t.Fatal(err)
	}
	listByID := make(map[string]types.ModelEntry, len(listResp.Data))
	for _, m := range listResp.Data {
		listByID[m.ID] = m
	}
	if _, baseOK := listByID[baseAlias]; !baseOK {
		t.Fatalf("standard source alias missing from /v1/models: %+v", listResp.Data)
	}
	if _, leaked := listByID[paidAlias]; leaked {
		t.Fatalf("OpenRouter-only alias leaked into /v1/models: %+v", listResp.Data)
	}
	if _, leaked := listByID[aliasQAT]; leaked {
		t.Fatalf("shared build leaked into /v1/models: %+v", listResp.Data)
	}

	// The dedicated feed clone differs from its source only in the three public
	// identities configured by the dedicated endpoint.
	orRec := httptest.NewRecorder()
	srv.handleListModelsOpenRouter(orRec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
	if orRec.Code != http.StatusOK {
		t.Fatalf("openrouter feed status = %d body = %s", orRec.Code, orRec.Body.String())
	}
	var orResp types.OpenRouterModelsResponse
	if err := json.Unmarshal(orRec.Body.Bytes(), &orResp); err != nil {
		t.Fatal(err)
	}
	orByID := make(map[string]types.OpenRouterModel, len(orResp.Data))
	for _, m := range orResp.Data {
		orByID[m.ID] = m
	}
	baseFeed, baseOK := orByID[baseAlias]
	paidFeed, paidOK := orByID[paidAlias]
	if !baseOK || !paidOK {
		t.Fatalf("aliases missing from OpenRouter feed: %+v", orResp.Data)
	}
	if paidFeed.OpenRouter == nil || paidFeed.OpenRouter.Slug != paidSlug || paidFeed.HuggingFaceID != paidHFID {
		t.Fatalf("paid feed identities: slug=%+v hugging_face_id=%q", paidFeed.OpenRouter, paidFeed.HuggingFaceID)
	}
	paidFeed.ID = baseFeed.ID
	paidFeed.HuggingFaceID = baseFeed.HuggingFaceID
	paidFeed.OpenRouter = baseFeed.OpenRouter
	if !reflect.DeepEqual(paidFeed, baseFeed) {
		t.Fatalf("OpenRouter clone differs beyond identities: source=%+v clone=%+v", baseFeed, paidFeed)
	}
	if _, leaked := orByID[aliasQAT]; leaked {
		t.Fatalf("shared build leaked into the OpenRouter feed: %+v", orResp.Data)
	}
	deleteReq := httptest.NewRequest(http.MethodDelete, "/v1/admin/models/openrouter-aliases/"+paidAlias, nil)
	deleteReq.Header.Set("Authorization", "Bearer publish-secret")
	deleteRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(deleteRec, deleteReq)
	if deleteRec.Code != http.StatusOK || reg.IsAlias(paidAlias) {
		t.Fatalf("delete OpenRouter alias: status=%d still_registered=%v body=%s", deleteRec.Code, reg.IsAlias(paidAlias), deleteRec.Body.String())
	}
}

// A concrete source remains independently listed while its OpenRouter-only
// clone shares routing, pricing, capacity, and every non-identity feed field.
func TestOpenRouterAliasClonesConcreteModel(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const (
		sourceID = "gpt-oss-20b"
		aliasID  = "openai-gpt-oss-20b"
		slug     = "openai/gpt-oss-20b"
		hfID     = "openai/gpt-oss-20b"
	)
	seedActiveModel(t, st, sourceID, "GPT-OSS 20B")
	if err := st.SetModelPrice("platform", sourceID, 20_000, 100_000); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, sourceID, testPublicKeyB64(), 50.0)
	defer conn.Close(websocket.StatusNormalClosure, "")

	body, _ := json.Marshal(map[string]any{
		"id": aliasID, "source_model": sourceID,
		"openrouter_slug": slug, "hugging_face_id": hfID,
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/openrouter-aliases", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("create concrete-source OpenRouter alias: status=%d body=%s", rec.Code, rec.Body.String())
	}

	if build, isAlias, ok := reg.ResolveModel(aliasID); !ok || !isAlias || build != sourceID {
		t.Fatalf("resolve clone = %q isAlias=%v ok=%v, want concrete source %q", build, isAlias, ok, sourceID)
	}
	if got := reg.PublicNameForBuild(sourceID); got != sourceID {
		t.Fatalf("OpenRouter alias became canonical name: got %q want %q", got, sourceID)
	}

	listRec := httptest.NewRecorder()
	srv.handleListModels(listRec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	if listRec.Code != http.StatusOK {
		t.Fatalf("list status = %d body=%s", listRec.Code, listRec.Body.String())
	}
	var listResp types.ModelListResponse
	if err := json.Unmarshal(listRec.Body.Bytes(), &listResp); err != nil {
		t.Fatal(err)
	}
	listByID := make(map[string]types.ModelEntry, len(listResp.Data))
	for _, model := range listResp.Data {
		listByID[model.ID] = model
	}
	sourceModel, sourceOK := listByID[sourceID]
	_, aliasLeaked := listByID[aliasID]
	if !sourceOK || aliasLeaked {
		t.Fatalf("standard catalog must list only the concrete source: %+v", listResp.Data)
	}
	if sourceModel.Pricing == nil || sourceModel.Pricing.Prompt != "0.00000002" || sourceModel.Pricing.Completion != "0.0000001" {
		t.Fatalf("source pricing = %+v", sourceModel.Pricing)
	}

	openRouterRec := httptest.NewRecorder()
	srv.handleListModelsOpenRouter(openRouterRec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
	if openRouterRec.Code != http.StatusOK {
		t.Fatalf("OpenRouter feed status = %d body=%s", openRouterRec.Code, openRouterRec.Body.String())
	}
	var openRouterResp types.OpenRouterModelsResponse
	if err := json.Unmarshal(openRouterRec.Body.Bytes(), &openRouterResp); err != nil {
		t.Fatal(err)
	}
	openRouterByID := make(map[string]types.OpenRouterModel, len(openRouterResp.Data))
	for _, model := range openRouterResp.Data {
		openRouterByID[model.ID] = model
	}
	sourceFeed, sourceOK := openRouterByID[sourceID]
	aliasFeed, aliasOK := openRouterByID[aliasID]
	if !sourceOK || !aliasOK {
		t.Fatalf("source and clone must both remain in OpenRouter feed: %+v", openRouterResp.Data)
	}
	if aliasFeed.HuggingFaceID != hfID || aliasFeed.OpenRouter == nil || aliasFeed.OpenRouter.Slug != slug {
		t.Fatalf("clone identities: hugging_face_id=%q openrouter=%+v", aliasFeed.HuggingFaceID, aliasFeed.OpenRouter)
	}
	aliasFeed.ID = sourceFeed.ID
	aliasFeed.HuggingFaceID = sourceFeed.HuggingFaceID
	aliasFeed.OpenRouter = sourceFeed.OpenRouter
	if !reflect.DeepEqual(aliasFeed, sourceFeed) {
		t.Fatalf("OpenRouter clone differs beyond identities: source=%+v clone=%+v", sourceFeed, aliasFeed)
	}
}

func TestOpenRouterAliasRejectsCoveredConcreteModel(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	const sourceID = "gpt-oss-20b"
	seedActiveModel(t, st, sourceID, "GPT-OSS 20B")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gpt-oss-public", DesiredBuild: sourceID, Active: true,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	body, _ := json.Marshal(map[string]any{
		"id": "openai-gpt-oss-20b", "source_model": sourceID,
		"openrouter_slug": "openai/gpt-oss-20b", "hugging_face_id": "openai/gpt-oss-20b",
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/openrouter-aliases", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "covered by standard alias gpt-oss-public") {
		t.Fatalf("covered concrete source: status=%d body=%s", rec.Code, rec.Body.String())
	}
	if _, found, err := st.GetModelAlias("openai-gpt-oss-20b"); err != nil || found {
		t.Fatalf("rejected clone persisted: found=%v err=%v", found, err)
	}
}

func TestStandardAliasRejectsConcreteSourceTakeover(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const (
		sourceID      = "gpt-oss-20b"
		replacementID = "gpt-oss-20b-v2"
		cloneID       = "openai-gpt-oss-20b"
	)
	seedActiveModel(t, st, sourceID, "GPT-OSS 20B")
	seedActiveModel(t, st, replacementID, "GPT-OSS 20B v2")
	srv.SyncModelCatalog()

	post := func(path string, payload map[string]any) *httptest.ResponseRecorder {
		t.Helper()
		body, _ := json.Marshal(payload)
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}
	if rec := post("/v1/admin/models/openrouter-aliases", map[string]any{
		"id": cloneID, "source_model": sourceID,
		"openrouter_slug": "openai/gpt-oss-20b", "hugging_face_id": "openai/gpt-oss-20b",
	}); rec.Code != http.StatusOK {
		t.Fatalf("create concrete clone: status=%d body=%s", rec.Code, rec.Body.String())
	}
	saved, found, err := st.GetModelAlias(cloneID)
	if err != nil || !found || saved.SourceKind != store.ModelAliasSourceConcrete {
		t.Fatalf("stored source kind: alias=%+v found=%v err=%v", saved, found, err)
	}

	rec := post("/v1/admin/models/aliases", map[string]any{
		"alias_id": sourceID, "desired_build": replacementID,
		"previous_build": sourceID, "takeover": true,
	})
	if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "pinned by OpenRouter alias "+cloneID) {
		t.Fatalf("takeover conflict: status=%d body=%s", rec.Code, rec.Body.String())
	}
	if build, isAlias, ok := reg.ResolveModel(cloneID); !ok || !isAlias || build != sourceID {
		t.Fatalf("clone retargeted after rejected takeover: build=%q isAlias=%v ok=%v", build, isAlias, ok)
	}
	if _, found, err := st.GetModelAlias(sourceID); err != nil || found {
		t.Fatalf("rejected takeover persisted: found=%v err=%v", found, err)
	}
}

func TestStandardAliasCoversEveryBuildState(t *testing.T) {
	for name, alias := range map[string]store.ModelAlias{
		"desired":  {Active: true, DesiredBuild: "source"},
		"previous": {Active: true, PreviousBuild: "source"},
		"retired":  {Active: true, RetiredBuilds: []string{"source"}},
	} {
		t.Run(name, func(t *testing.T) {
			if !standardAliasCoversBuild(alias, "source") {
				t.Fatalf("%s build was not covered: %+v", name, alias)
			}
		})
	}
}

func TestOpenRouterAliasFollowsSourceAliasBuildUpdate(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	seedActiveModel(t, st, aliasQAT, "Gemma 4 26B QAT")
	seedActiveModel(t, st, aliasFP8, "Gemma 4 26B FP8")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DesiredBuild: aliasQAT, Active: true,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b-paid", OpenRouterOnly: true,
		SourceModel: "gemma-4-26b", OpenRouterSlug: "google/gemma-4-26b-it",
		HuggingFaceID: "google/gemma-4-26b-it", Active: true,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()
	if build, _, ok := reg.ResolveModel("gemma-4-26b-paid"); !ok || build != aliasQAT {
		t.Fatalf("initial OpenRouter alias resolve = %q ok=%v", build, ok)
	}

	// Move only the source alias. The OpenRouter clone follows without its own
	// rollout update because sync resolves its route through SourceModel.
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DesiredBuild: aliasFP8, PreviousBuild: aliasQAT, Active: true,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()
	if build, _, ok := reg.ResolveModel("gemma-4-26b-paid"); !ok || build != aliasFP8 {
		t.Fatalf("updated OpenRouter alias resolve = %q ok=%v, want source desired %q", build, ok, aliasFP8)
	}
}
