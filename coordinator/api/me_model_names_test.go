package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// seedActiveCatalogModel registers a model in the DB-backed registry with a
// promoted version so SyncModelCatalog publishes it to the live catalog.
func seedActiveCatalogModel(t *testing.T, st *store.MemoryStore, id, displayName string) {
	t.Helper()
	entry := &store.ModelRegistryEntry{ID: id, DisplayName: displayName, Status: "active"}
	version := &store.ModelVersion{ModelID: id, Version: "v1", R2Prefix: modelR2Prefix(id, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 9_000_000_000, FileCount: 1, Status: "ready"}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(id, "v1"); err != nil {
		t.Fatal(err)
	}
}

type myProvidersNamesResp struct {
	Providers         []struct{ ID string } `json:"providers"`
	ModelDisplayNames map[string]string     `json:"model_display_names"`
}

// TestMyProvidersModelDisplayNames pins the dashboard's name source: the
// published catalog display names ride on /v1/me/providers, keyed by the raw
// build ID the provider advertises, so chips can show "Qwen 3.8 27B" instead of
// "EigenLabs/Qwen3.8-27B-4bit-mtp". A row whose display name merely repeats its
// ID is omitted so the UI applies its own raw-ID fallback.
func TestMyProvidersModelDisplayNames(t *testing.T) {
	srv, st := newKeyTestServer(t)
	const qwen27, moe, unnamed = "EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "gpt-oss-20b"
	seedActiveCatalogModel(t, st, qwen27, "Qwen 3.8 27B")
	seedActiveCatalogModel(t, st, moe, "Qwen 3.6 35B A3B")
	seedActiveCatalogModel(t, st, unnamed, unnamed)
	srv.SyncModelCatalog()

	p := srv.registry.Register("p-live", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: qwen27, WeightHash: testHash}, {ID: moe, WeightHash: testHash}},
	})
	p.Mu().Lock()
	p.AccountID = "acct-1"
	p.Mu().Unlock()

	w := httptest.NewRecorder()
	srv.handleMyProviders(w, reqWithUser(http.MethodGet, "/v1/me/providers", "", "acct-1"))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp myProvidersNamesResp
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Providers) != 1 {
		t.Fatalf("providers = %d, want 1: %s", len(resp.Providers), w.Body.String())
	}
	want := map[string]string{qwen27: "Qwen 3.8 27B", moe: "Qwen 3.6 35B A3B"}
	if !reflect.DeepEqual(resp.ModelDisplayNames, want) {
		t.Fatalf("model_display_names = %v, want %v", resp.ModelDisplayNames, want)
	}
}

// TestMyProvidersModelDisplayNamesAlwaysObject: consoles index into the map
// unconditionally, so a coordinator without a catalog must still send {} — never
// null and never a missing key.
func TestMyProvidersModelDisplayNamesAlwaysObject(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, reqWithUser(http.MethodGet, "/v1/me/providers", "", "acct-1"))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(w.Body.Bytes(), &raw); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if string(raw["model_display_names"]) != "{}" {
		t.Fatalf("model_display_names = %s, want {}", raw["model_display_names"])
	}
}
