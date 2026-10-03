package catalog_test

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/api"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// Fixture addresses are independent of catalog's address builder. Exact address
// validation is tested beside that builder, not by comparing it to itself.
func testModelPrefix(model, version string) string {
	slug := strings.Trim(regexp.MustCompile(`[^a-zA-Z0-9._-]`).ReplaceAllString(model, "-"), "-")
	if slug == "" {
		slug = "model"
	}
	sum := sha256.Sum256([]byte(model))
	return fmt.Sprintf("v2/%s--%x/%s", slug, sum[:6], version)
}

func catalogFeedEntry(t *testing.T, s *api.Server, model string) types.OpenRouterModel {
	t.Helper()
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil)
	r.Header.Set("Authorization", "Bearer test-key")
	s.Handler().ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("feed: %d %s", w.Code, w.Body.String())
	}
	var response types.OpenRouterModelsResponse
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	for _, entry := range response.Data {
		if entry.ID == model {
			return entry
		}
	}
	t.Fatalf("model %q missing from feed", model)
	return types.OpenRouterModel{}
}

const testHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
