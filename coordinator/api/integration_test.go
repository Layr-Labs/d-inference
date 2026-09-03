package api

import (
	"context"
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

// TestIntegration_ProviderReconnectRequiresChallenge verifies that a provider
// that disconnects and reconnects is NOT routable until it passes a new challenge.
func TestIntegration_ProviderReconnectRequiresChallenge(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 100 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "reconnect-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	first := newTestProviderWS(t, ctx, ts.URL, reg, models, pubKey)
	first.MakeRoutable(model)
	firstSessionID := first.providerID
	first.Close(websocket.StatusNormalClosure, "done")

	// --- Phase 3: Reconnect with a new connection ---
	second := newTestProviderWS(t, ctx, ts.URL, reg, models, pubKey)
	defer second.Close(websocket.StatusNormalClosure, "")
	if second.providerID == firstSessionID {
		t.Fatalf("reconnect reused session id %q", firstSessionID)
	}
	reg.SetTrustLevel(second.providerID, registry.TrustHardware)

	if p := findRoutableProvider(reg, model); p != nil {
		t.Fatalf("provider %q routed before reconnect challenge", p.ID)
	}

	second.RespondToChallenge(func(data []byte) []byte {
		return makeValidChallengeResponse(data, pubKey)
	})
	awaitTestCondition(t, ctx, "reconnected provider routability", func() bool {
		p := findRoutableProvider(reg, model)
		return p != nil && p.ID == second.providerID
	})
}
