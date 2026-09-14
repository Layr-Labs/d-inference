package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// TestIntegration_ProviderEvictionRemovesFromRouting verifies that when a
// provider's WebSocket connection closes, it is removed from the registry
// and is no longer routable.
func TestIntegration_ProviderEvictionRemovesFromRouting(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "eviction-routing-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)

	// Handle the initial challenge so the provider becomes routable.
	challengeDone := make(chan struct{})
	go func() {
		defer close(challengeDone)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				return
			}
		}
	}()

	select {
	case <-challengeDone:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for challenge")
	}
	time.Sleep(200 * time.Millisecond)

	// Set trust and verify routable.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	p := findRoutableProvider(reg, model)
	if p == nil {
		t.Fatal("provider should be routable before disconnect")
	}
	reg.SetProviderIdle(p.ID)

	// Close the WebSocket to simulate provider disconnect.
	conn.Close(websocket.StatusNormalClosure, "test disconnect")

	// Wait for the server to process the disconnect.
	time.Sleep(500 * time.Millisecond)

	// Verify provider is gone.
	if reg.ProviderCount() != 0 {
		t.Errorf("ProviderCount = %d, want 0 after disconnect", reg.ProviderCount())
	}
	if findRoutableProvider(reg, model) != nil {
		t.Error("routing should return nil after provider disconnects")
	}
}
