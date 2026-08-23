package api

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

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

type aliasMutationRaceStore struct {
	store.Store
	mu      sync.Mutex
	armed   bool
	calls   int
	release chan struct{}
	once    sync.Once
}

func (s *aliasMutationRaceStore) arm() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.armed = true
	s.calls = 0
	s.release = make(chan struct{})
	s.once = sync.Once{}
}

func (s *aliasMutationRaceStore) ListModelAliases() ([]store.ModelAlias, error) {
	aliases, err := s.Store.ListModelAliases()
	s.mu.Lock()
	if !s.armed {
		s.mu.Unlock()
		return aliases, err
	}
	s.calls++
	call := s.calls
	if call == 2 {
		s.once.Do(func() { close(s.release) })
	}
	release := s.release
	s.mu.Unlock()
	if call <= 2 {
		select {
		case <-release:
		case <-time.After(100 * time.Millisecond):
		}
	}
	return aliases, err
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

func TestAliasMutationEndpointsSerializeOwnershipChecks(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	memoryStore := store.NewMemory(store.Config{})
	raceStore := &aliasMutationRaceStore{Store: memoryStore}
	srv := NewServer(registry.New(logger), raceStore, ServerConfig{}, logger)

	const sourceID = "gpt-oss-20b"
	seedActiveModel(t, raceStore, sourceID, "GPT-OSS 20B")
	srv.SyncModelCatalog()
	raceStore.arm()

	start := make(chan struct{})
	statuses := make(chan int, 2)
	post := func(path string, payload map[string]any) {
		<-start
		body, _ := json.Marshal(payload)
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		statuses <- rec.Code
	}
	go post("/v1/admin/models/openrouter-aliases", map[string]any{
		"id": "openai-gpt-oss-20b", "source_model": sourceID,
		"openrouter_slug": "openai/gpt-oss-20b", "hugging_face_id": "openai/gpt-oss-20b",
	})
	go post("/v1/admin/models/aliases", map[string]any{
		"alias_id": "gpt-oss-public", "desired_build": sourceID,
	})
	close(start)

	successes, conflicts := 0, 0
	for range 2 {
		switch status := <-statuses; status {
		case http.StatusOK:
			successes++
		case http.StatusConflict:
			conflicts++
		default:
			t.Fatalf("unexpected concurrent mutation status: %d", status)
		}
	}
	if successes != 1 || conflicts != 1 {
		t.Fatalf("concurrent mutations: successes=%d conflicts=%d", successes, conflicts)
	}
	aliases, err := memoryStore.ListModelAliases()
	if err != nil || len(aliases) != 1 {
		t.Fatalf("persisted aliases after concurrent mutations: aliases=%+v err=%v", aliases, err)
	}
}

