package catalog_test

// End-to-end HTTP tests for the "use my own machine, for free" (self-route)
// feature. They exercise the real handler path (auth → policy → routing →
// settlement) through httptest.NewServer, with a simulated provider over the
// WebSocket harness shared with the billing integration tests.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

// TestSelfRouteOnlyKeyListsAliasForOwnedCatalogBuild verifies the self-route
// /v1/models view preserves public alias naming: an owned machine serving a
// catalog build behind an active alias is listed under the alias id (the
// documented name inference resolves), the concrete build is hidden like the
// public list, and retrieve-by-exact-id still works for both names.
func TestSelfRouteOnlyKeyListsAliasForOwnedCatalogBuild(t *testing.T) {
	f, _ := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const owner = "owner-alias"
	raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{Name: "mine", SelfRouteOnly: true})
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}

	const build = "gemma-4-26b-8bit"
	const alias = "gemma-4-26b"
	conn, _, _ := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, build)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, owner)
	f.Registry.SetModelCatalog([]registry.CatalogEntry{{ID: build}})
	if err := st.UpsertModelAlias(&store.ModelAlias{AliasID: alias, DesiredBuild: build, Active: true}); err != nil {
		t.Fatalf("UpsertModelAlias: %v", err)
	}

	fetch := func(path string) (int, []byte) {
		t.Helper()
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+path, nil)
		req.Header.Set("Authorization", "Bearer "+raw)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, body
	}

	status, body := fetch("/v1/models")
	if status != http.StatusOK {
		t.Fatalf("list status = %d body = %s", status, body)
	}
	var listed types.ModelListResponse
	if err := json.Unmarshal(body, &listed); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(listed.Data) != 1 || listed.Data[0].ID != alias {
		t.Fatalf("listed = %+v, want only the alias %q (build hidden)", listed.Data, alias)
	}

	// Retrieve works for the alias AND for the concrete build (exact-id parity
	// with the public retrieve endpoint's hidden-build behavior).
	if status, body := fetch("/v1/models/" + alias); status != http.StatusOK {
		t.Fatalf("retrieve alias status = %d body = %s", status, body)
	}
	if status, body := fetch("/v1/models/" + build); status != http.StatusOK {
		t.Fatalf("retrieve hidden build status = %d body = %s", status, body)
	}
}

// TestSelfRouteModelViewRespectsKeyAllowListAndPickerEndpoint covers the two
// consumers of the alias-aware owned-model view beyond the plain list:
//
//  1. GET /v1/me/self-route-models (the console picker source) returns the
//     SAME ids /v1/models shows a self-route key — aliases, not hidden builds
//     — so a picker-created allow-list can never reject the listed name.
//  2. A self-route-only key with an allow-list only sees its allowed models:
//     owned live models are private inventory, and a restricted key handed
//     out for one model must not enumerate the rest.
func TestSelfRouteModelViewRespectsKeyAllowListAndPickerEndpoint(t *testing.T) {
	f, _ := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const owner = "owner-allowlist"
	const build = "gemma-4-26b-8bit"
	const alias = "gemma-4-26b"
	conn, _, _ := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, build)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, owner)
	f.Registry.SetModelCatalog([]registry.CatalogEntry{{ID: build}})
	if err := st.UpsertModelAlias(&store.ModelAlias{AliasID: alias, DesiredBuild: build, Active: true}); err != nil {
		t.Fatalf("UpsertModelAlias: %v", err)
	}

	// 1. Picker endpoint returns the alias id, not the hidden build.
	rec := httptest.NewRecorder()
	pickerReq := httptest.NewRequest(http.MethodGet, "/v1/me/self-route-models", nil)
	pickerReq.Header.Set("Authorization", "Bearer "+testkit.NewSessions(t, srv, st).Token(owner))
	srv.Handler().ServeHTTP(rec, pickerReq)
	if rec.Code != http.StatusOK {
		t.Fatalf("picker endpoint status = %d body = %s", rec.Code, rec.Body.String())
	}
	var picker struct {
		Models []string `json:"models"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &picker); err != nil {
		t.Fatalf("decode picker response: %v", err)
	}
	if len(picker.Models) != 1 || picker.Models[0] != alias {
		t.Fatalf("picker models = %v, want [%q] (alias, not hidden build)", picker.Models, alias)
	}

	// 2. Allow-list restricts the self-route model view.
	listFor := func(allowed []string) []types.ModelEntry {
		t.Helper()
		raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{Name: "k", SelfRouteOnly: true, AllowedModels: allowed})
		if err != nil {
			t.Fatalf("CreateAPIKey: %v", err)
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/v1/models", nil)
		req.Header.Set("Authorization", "Bearer "+raw)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("list models: %v", err)
		}
		defer resp.Body.Close()
		var listed types.ModelListResponse
		if err := json.NewDecoder(resp.Body).Decode(&listed); err != nil {
			t.Fatalf("decode list: %v", err)
		}
		return listed.Data
	}
	if got := listFor([]string{alias}); len(got) != 1 || got[0].ID != alias {
		t.Fatalf("alias-allowed key sees %+v, want just %q", got, alias)
	}
	if got := listFor([]string{"some-unrelated-model"}); len(got) != 0 {
		t.Fatalf("restricted key enumerates owned inventory: %+v", got)
	}
	if got := listFor(nil); len(got) != 1 {
		t.Fatalf("unrestricted key sees %+v, want the full owned view", got)
	}
}

// TestHeaderSelfRouteSeesOwnedModelView verifies the /v1/models view follows
// the request's resolved route mode, not just the per-key flag: an ordinary
// key sending X-Darkbloom-Route: self (which CAN infer against owned
// off-catalog models) discovers them in list and retrieve, while the same key
// without the header keeps the public catalog view.
func TestHeaderSelfRouteSeesOwnedModelView(t *testing.T) {
	f, _ := testkit.NewBilling(t)
	srv, st := f.Server, f.Store
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	const owner = "owner-header"
	raw, _, err := st.CreateAPIKey(owner, store.APIKeyCreate{Name: "normal"}) // NOT SelfRouteOnly
	if err != nil {
		t.Fatalf("CreateAPIKey: %v", err)
	}

	model := "local/off-catalog-header"
	conn, _, _ := testkit.SetupProviderForBilling(t, ctx, ts, f.Registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	testkit.SetProviderOwner(f.Registry, owner)
	f.Registry.SetModelCatalog([]registry.CatalogEntry{{ID: "catalog-only-model"}})

	list := func(selfHeader bool) types.ModelListResponse {
		t.Helper()
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/v1/models", nil)
		req.Header.Set("Authorization", "Bearer "+raw)
		if selfHeader {
			req.Header.Set("X-Darkbloom-Route", "self")
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("list models: %v", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(resp.Body)
			t.Fatalf("list status = %d body = %s", resp.StatusCode, body)
		}
		var listed types.ModelListResponse
		if err := json.NewDecoder(resp.Body).Decode(&listed); err != nil {
			t.Fatalf("decode list: %v", err)
		}
		return listed
	}

	// With the header: the owned view, exactly what header-based inference
	// accepts.
	withHeader := list(true)
	if len(withHeader.Data) != 1 || withHeader.Data[0].ID != model || withHeader.Data[0].OwnedBy != "self" {
		t.Fatalf("header list = %+v, want the owned off-catalog model %q", withHeader.Data, model)
	}
	// Retrieve agrees with list under the header.
	getReq, _ := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/v1/models/"+model, nil)
	getReq.Header.Set("Authorization", "Bearer "+raw)
	getReq.Header.Set("X-Darkbloom-Route", "self")
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatalf("retrieve: %v", err)
	}
	getResp.Body.Close()
	if getResp.StatusCode != http.StatusOK {
		t.Fatalf("header retrieve status = %d, want 200", getResp.StatusCode)
	}

	// Without the header: the public catalog view (the off-catalog local
	// model must not appear — this key's headerless inference is public).
	noHeader := list(false)
	for _, e := range noHeader.Data {
		if e.ID == model {
			t.Fatalf("headerless list leaked the off-catalog model: %+v", noHeader.Data)
		}
	}
}
