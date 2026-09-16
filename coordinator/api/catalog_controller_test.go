package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The mounted catalog routes must keep current publishing credentials and
// persistence bindings. A successful mutation also publishes routing state and
// removes the previously cached listing before the next request.
func TestCatalogControllerUsesCurrentBindingsAndInvalidatesPublishedViews(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "")
	srv, initial := newKeyTestServer(t)
	t.Cleanup(srv.Close)
	const modelID, replacementID = "catalog-controller-model", "catalog-controller-replacement"
	seedActiveModel(t, initial, modelID, "Before replacement")
	srv.SyncModelCatalog()
	srv.SetAdminKey("catalog-admin-before")
	handler := srv.Handler()
	request := func(method, path, token, body string, want int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s %s: status=%d want=%d body=%s", method, path, w.Code, want, w.Body.String())
		}
		return w
	}
	feed := func(token, wantID, wantName string) types.OpenRouterModel {
		t.Helper()
		w := request(http.MethodGet, "/v1/models/openrouter", token, "", http.StatusOK)
		var response types.OpenRouterModelsResponse
		if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if len(response.Data) != 1 || response.Data[0].ID != wantID || response.Data[0].Name != wantName {
			t.Fatalf("feed=%+v, want the current %q model", response.Data, wantName)
		}
		return response.Data[0]
	}
	feed("catalog-admin-before", modelID, "Before replacement")
	request(http.MethodGet, "/v1/models/catalog", "", "", http.StatusOK)

	replacement := store.NewMemory(store.Config{})
	seedActiveModel(t, replacement, replacementID, "After replacement")
	// Existing API fixtures replace persistence after routes are mounted. The
	// controller must resolve that same live binding for reads and writes.
	srv.store = replacement
	srv.SetAdminKey("catalog-admin-after")
	path := "/v1/admin/models/" + replacementID + "/capabilities"
	body := `{"capabilities":["tools","reasoning"]}`
	request(http.MethodPost, path, "catalog-admin-before", body, http.StatusUnauthorized)
	request(http.MethodPost, path, "catalog-admin-after", body, http.StatusOK)
	old, err := initial.GetModelRegistryRecord(modelID)
	if err != nil {
		t.Fatal(err)
	}
	if len(old.Capabilities) != 1 || old.Capabilities[0] != "chat" {
		t.Fatalf("mutation reached the replaced store: %+v", old.Capabilities)
	}
	current, err := replacement.GetModelRegistryRecord(replacementID)
	if err != nil {
		t.Fatal(err)
	}
	if len(current.Capabilities) != 2 || current.Capabilities[0] != "tools" || current.Capabilities[1] != "reasoning" {
		t.Fatalf("current store did not receive capabilities: %+v", current.Capabilities)
	}
	if !srv.registry.IsModelInCatalog(replacementID) || srv.registry.IsModelInCatalog(modelID) {
		t.Fatal("successful mutation did not publish the routing catalog")
	}
	model := feed("catalog-admin-after", replacementID, "After replacement")
	if len(model.SupportedFeatures) != 2 || model.SupportedFeatures[0] != "reasoning" || model.SupportedFeatures[1] != "tools" {
		t.Fatalf("cached feed did not observe the mutation: %+v", model.SupportedFeatures)
	}
	w := request(http.MethodGet, "/v1/models/catalog", "", "", http.StatusOK)
	var install struct {
		Models []struct {
			ID           string   `json:"id"`
			DisplayName  string   `json:"display_name"`
			Capabilities []string `json:"capabilities"`
		} `json:"models"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &install); err != nil {
		t.Fatal(err)
	}
	if len(install.Models) != 1 || install.Models[0].ID != replacementID || install.Models[0].DisplayName != "After replacement" || len(install.Models[0].Capabilities) != 2 {
		t.Fatalf("cached install catalog did not observe the mutation: %+v", install.Models)
	}
	srv.SetAdminKey("")
	request(http.MethodPost, path, "catalog-admin-after", body, http.StatusUnauthorized)
}
