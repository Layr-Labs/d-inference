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
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

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

	retrieveReq := httptest.NewRequest(http.MethodGet, "/v1/models/"+paidAlias, nil)
	retrieveReq.SetPathValue("id", paidAlias)
	retrieveRec := httptest.NewRecorder()
	srv.handleGetModel(retrieveRec, retrieveReq)
	if retrieveRec.Code != http.StatusOK {
		t.Fatalf("retrieve hidden OpenRouter alias: status=%d body=%s", retrieveRec.Code, retrieveRec.Body.String())
	}
	var retrieved types.ModelEntry
	if err := json.Unmarshal(retrieveRec.Body.Bytes(), &retrieved); err != nil {
		t.Fatal(err)
	}
	if retrieved.ID != paidAlias || retrieved.HuggingFaceID != paidHFID {
		t.Fatalf("retrieved alias identities: %+v", retrieved)
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

	retrieveReq := httptest.NewRequest(http.MethodGet, "/v1/models/"+aliasID, nil)
	retrieveReq.SetPathValue("id", aliasID)
	retrieveRec := httptest.NewRecorder()
	srv.handleGetModel(retrieveRec, retrieveReq)
	if retrieveRec.Code != http.StatusOK {
		t.Fatalf("retrieve hidden concrete-source alias: status=%d body=%s", retrieveRec.Code, retrieveRec.Body.String())
	}
	var retrieved types.ModelEntry
	if err := json.Unmarshal(retrieveRec.Body.Bytes(), &retrieved); err != nil {
		t.Fatal(err)
	}
	if retrieved.ID != aliasID || retrieved.HuggingFaceID != hfID || !reflect.DeepEqual(retrieved.Pricing, sourceModel.Pricing) {
		t.Fatalf("retrieved concrete-source alias: %+v", retrieved)
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

func TestOpenRouterAliasConcreteRetrievalWithoutProviders(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)

	const (
		sourceID = "gpt-oss-20b"
		aliasID  = "openai-gpt-oss-20b"
		hfID     = "openai/gpt-oss-20b"
	)
	seedActiveModel(t, st, sourceID, "GPT-OSS 20B")
	if err := st.SetModelPrice("platform", sourceID, 20_000, 100_000); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	body, _ := json.Marshal(map[string]any{
		"id": aliasID, "source_model": sourceID,
		"openrouter_slug": "openai/gpt-oss-20b", "hugging_face_id": hfID,
	})
	createReq := httptest.NewRequest(http.MethodPost, "/v1/admin/models/openrouter-aliases", bytes.NewReader(body))
	createReq.Header.Set("Authorization", "Bearer publish-secret")
	createRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(createRec, createReq)
	if createRec.Code != http.StatusOK {
		t.Fatalf("create concrete clone: status=%d body=%s", createRec.Code, createRec.Body.String())
	}

	retrieveReq := httptest.NewRequest(http.MethodGet, "/v1/models/"+aliasID, nil)
	retrieveReq.SetPathValue("id", aliasID)
	retrieveRec := httptest.NewRecorder()
	srv.handleGetModel(retrieveRec, retrieveReq)
	if retrieveRec.Code != http.StatusOK {
		t.Fatalf("retrieve zero-provider concrete clone: status=%d body=%s", retrieveRec.Code, retrieveRec.Body.String())
	}
	var retrieved types.ModelEntry
	if err := json.Unmarshal(retrieveRec.Body.Bytes(), &retrieved); err != nil {
		t.Fatal(err)
	}
	if retrieved.ID != aliasID || retrieved.HuggingFaceID != hfID {
		t.Fatalf("retrieved identities: %+v", retrieved)
	}
	if retrieved.Pricing == nil || retrieved.Pricing.Prompt != "0.00000002" || retrieved.Pricing.Completion != "0.0000001" {
		t.Fatalf("retrieved pricing: %+v", retrieved.Pricing)
	}
	if retrieved.Metadata.ProviderCount != 0 || retrieved.Metadata.RoutableProviders != 0 {
		t.Fatalf("zero-provider metadata: %+v", retrieved.Metadata)
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

func TestOpenRouterAliasUsesConcreteModelShadowedByInactiveAlias(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	const (
		sourceID = "gpt-oss-20b"
		cloneID  = "openai-gpt-oss-20b"
	)
	seedActiveModel(t, st, sourceID, "GPT-OSS 20B")
	seedActiveModel(t, st, "gpt-oss-20b-v2", "GPT-OSS 20B v2")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: sourceID, DesiredBuild: "gpt-oss-20b-v2",
		PreviousBuild: sourceID, Active: false,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	body, _ := json.Marshal(map[string]any{
		"id": cloneID, "source_model": sourceID,
		"openrouter_slug": "openai/gpt-oss-20b", "hugging_face_id": "openai/gpt-oss-20b",
	})
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/openrouter-aliases", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer publish-secret")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("create clone from concrete model shadowed by inactive alias: status=%d body=%s", rec.Code, rec.Body.String())
	}
	saved, found, err := st.GetModelAlias(cloneID)
	if err != nil || !found || saved.SourceKind != store.ModelAliasSourceConcrete {
		t.Fatalf("stored source kind: alias=%+v found=%v err=%v", saved, found, err)
	}
	if build, isAlias, ok := reg.ResolveModel(cloneID); !ok || !isAlias || build != sourceID {
		t.Fatalf("concrete clone resolve: build=%q isAlias=%v ok=%v", build, isAlias, ok)
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
