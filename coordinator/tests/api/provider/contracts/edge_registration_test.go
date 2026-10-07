package provider_test

import (
	"context"
	"fmt"
	"log/slog"
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

func TestEdge_ProviderEmptyModels(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register a provider with no models
	conn := testkit.ConnectProvider(t, ctx, ts.URL, []protocol.ModelInfo{}, testkit.PublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Provider should register but not be findable for any model
	time.Sleep(200 * time.Millisecond)
	if p := testkit.FindRoutableProvider(reg, "any-model"); p != nil {
		t.Error("provider with no models should not be findable")
	}
}

func TestEdge_ProviderDuplicateModelsRejected(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register with duplicate model entries
	models := []protocol.ModelInfo{
		{ID: "dupe-model", ModelType: "chat", Quantization: "4bit"},
		{ID: "dupe-model", ModelType: "chat", Quantization: "4bit"},
		{ID: "dupe-model", ModelType: "chat", Quantization: "8bit"},
	}
	conn := testkit.ConnectProvider(t, ctx, ts.URL, models, testkit.PublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")

	time.Sleep(200 * time.Millisecond)
	// Ambiguous per-model capabilities are invalid: reject the entire
	// registration instead of silently choosing one duplicate.
	if reg.ProviderCount() != 0 {
		t.Errorf("expected duplicate registration rejection, got %d providers", reg.ProviderCount())
	}
}

func TestEdge_ProviderVeryLargeRegistration(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register with many models
	var models []protocol.ModelInfo
	for i := range 100 {
		models = append(models, protocol.ModelInfo{
			ID:           fmt.Sprintf("model-%d", i),
			ModelType:    "chat",
			Quantization: "4bit",
		})
	}
	conn := testkit.ConnectProvider(t, ctx, ts.URL, models, testkit.PublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")

	time.Sleep(200 * time.Millisecond)
	if reg.ProviderCount() != 1 {
		t.Errorf("expected 1 provider, got %d", reg.ProviderCount())
	}
}

func TestEdge_CatalogChangeDuringActiveProvider(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	srv.SetChallengeInterval(100 * time.Millisecond)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	model := "dynamic-model"
	pubKey := testkit.PublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	// No catalog set — model should be allowed
	conn := testkit.ConnectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle the first challenge
	go testkit.HandleProviderMessages(ctx, t, conn, func(msgType string, data []byte) []byte {
		if msgType == protocol.TypeAttestationChallenge {
			return testkit.MakeValidChallengeResponse(data, pubKey)
		}
		return nil
	})

	time.Sleep(300 * time.Millisecond)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	// Model should be findable (no catalog = allow all)
	if p := testkit.FindRoutableProvider(reg, model); p == nil {
		t.Fatal("provider should be findable with no catalog")
	}

	// Now set a catalog that excludes this model
	reg.SetModelCatalog([]registry.CatalogEntry{
		{ID: "other-model"},
	})

	// Model should now be rejected by catalog check
	if reg.IsModelInCatalog(model) {
		t.Error("model should not be in catalog after change")
	}
}

func TestEdge_ProviderInvalidPublicKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Register with invalid base64 public key
	models := []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}}
	conn := testkit.ConnectProvider(t, ctx, ts.URL, models, "not-valid-base64!!!")
	defer conn.Close(websocket.StatusNormalClosure, "")

	time.Sleep(200 * time.Millisecond)
	// Provider should still register (key validation happens at encryption time)
	// but requests to it should fail gracefully
}
