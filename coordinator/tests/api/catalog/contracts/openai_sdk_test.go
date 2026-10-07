package catalog_test

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	api "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

func TestOpenAI_ListModelsFormat(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Connect a provider with a model.
	pubKey := testkit.PublicKeyB64()
	conn := testkit.ConnectProvider(t, ctx, ts.URL,
		[]protocol.ModelInfo{{ID: "gpt-test", ModelType: "chat", Quantization: "4bit"}},
		pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Trust the provider.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", w.Code, w.Body.String())
	}

	var result map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	// object = "list".
	if result["object"] != "list" {
		t.Errorf("object = %v, want %q", result["object"], "list")
	}

	// data array.
	data, ok := result["data"].([]any)
	if !ok {
		t.Fatalf("data is not an array: %T", result["data"])
	}

	if len(data) == 0 {
		t.Fatal("data array is empty, expected at least 1 model")
	}

	for i, item := range data {
		model, ok := item.(map[string]any)
		if !ok {
			t.Errorf("data[%d] is not an object", i)
			continue
		}

		// Each model must have id.
		if _, ok := model["id"].(string); !ok {
			t.Errorf("data[%d]: missing or invalid 'id'", i)
		}

		// object = "model".
		if model["object"] != "model" {
			t.Errorf("data[%d]: object = %v, want %q", i, model["object"], "model")
		}

		// created (timestamp, may be 0).
		if _, ok := model["created"].(float64); !ok {
			t.Errorf("data[%d]: missing or invalid 'created' timestamp", i)
		}

		// owned_by.
		if _, ok := model["owned_by"].(string); !ok {
			t.Errorf("data[%d]: missing or invalid 'owned_by'", i)
		}
	}
}

func TestOpenAI_SDK_UnimplementedEndpoint_GetModel(t *testing.T) {
	srv := testkit.New(
		t,
		api.ServerConfig{},
	).Server

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	client := testkit.NewSDKClientForCompat(t, ts)

	_, err := client.Models.Get(context.Background(), "nonexistent-model")
	if err == nil {
		t.Fatal("expected error from unimplemented endpoint, got nil")
	}

	apiErr := testkit.AsSDKError(err)
	if apiErr == nil {
		t.Fatalf("expected openai.Error, got %T: %v", err, err)
	}
	if apiErr.StatusCode != 404 {
		t.Errorf("expected 404, got %d", apiErr.StatusCode)
	}
	if apiErr.Type == "" {
		t.Error("error type should not be empty")
	}
}

func TestOpenAI_SDK_ModelCatalog(t *testing.T) {
	srv := testkit.New(
		t,
		api.ServerConfig{},
	).Server

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	client := testkit.NewSDKClientForCompat(t, ts)

	var result struct {
		Models []struct {
			ID       string `json:"id"`
			SizeGB   int    `json:"size_gb"`
			ModelTag string `json:"model_tag"`
		} `json:"models"`
	}
	err := client.Execute(context.Background(), "GET", "/models/catalog", nil, &result)
	if err != nil {
		t.Fatalf("expected model catalog to succeed, got: %v", err)
	}
}
