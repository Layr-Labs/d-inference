package catalog_test

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestPreloadLongModelIDAuthenticatedRegistration(t *testing.T) {
	manifest := validTestManifest()
	manifest.ModelID = strings.Repeat("m", 513)
	manifest.R2Prefix = testModelPrefix(manifest.ModelID, manifest.Version)
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/" + manifest.R2Prefix + "/manifest.json":
			_ = json.NewEncoder(w).Encode(manifest)
		case "/" + manifest.R2Prefix + "/config.json":
			w.Header().Set("Content-Length", "123")
		default:
			http.NotFound(w, r)
		}
	}))
	defer cdn.Close()
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdn.URL)
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	st := memory.NewMemory(store.Config{})
	srv := api.NewServer(reg, st, api.ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	body, err := json.Marshal(map[string]any{
		"hugging_face_artifact": &store.HuggingFaceArtifact{RepoID: "EigenLabs/test", Revision: "0123456789abcdef0123456789abcdef01234567", PathPrefix: "mlx"},
		"model_id":              manifest.ModelID, "version": manifest.Version, "quantization": "4bit",
		"max_context_length": 32768, "max_output_length": 8192, "min_ram_gb": 16,
		"capabilities": []string{"chat"}, "promote": true, "input_price": 50000, "output_price": 200000,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, authorized := range []bool{false, true} {
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/register", bytes.NewReader(body))
		if authorized {
			req.Header.Set("Authorization", "Bearer publish-secret")
		}
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		if !authorized {
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("unauthenticated registration status=%d", rec.Code)
			}
			continue
		}
		if rec.Code != http.StatusOK || !reg.IsModelInCatalog(manifest.ModelID) {
			t.Fatalf("authenticated 513-byte ID registration: status=%d body=%s", rec.Code, rec.Body.String())
		}
	}
}
