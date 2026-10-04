package provider_test

import (
	"context"
	"encoding/json"
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

// TestIntegration_ProviderReconnectRequiresChallenge verifies that a provider
// that disconnects and reconnects is NOT routable until it passes a new challenge.
func TestIntegration_ProviderReconnectRequiresChallenge(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	srv.SetChallengeInterval(100 * time.Millisecond)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKey := testkit.PublicKeyB64()
	model := "reconnect-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	// --- Phase 1: Connect, handle challenge, verify routable ---
	conn1 := testkit.ConnectProvider(t, ctx, ts.URL, models, pubKey)

	// Handle the first challenge (arrives after ~100ms).
	challengeHandled := make(chan struct{})
	go func() {
		defer close(challengeHandled)
		for {
			_, data, err := conn1.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				resp := testkit.MakeValidChallengeResponse(data, pubKey)
				conn1.Write(ctx, websocket.MessageText, resp)
				return
			}
		}
	}()

	select {
	case <-challengeHandled:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for first challenge")
	}

	// Wait for verification to complete.
	time.Sleep(200 * time.Millisecond)

	// Set trust level (challenges verify liveness, but trust level is set
	// separately — simulating attestation verification).
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	// Provider should be routable now.
	p := testkit.FindRoutableProvider(reg, model)
	if p == nil {
		t.Fatal("provider should be routable after passing challenge")
	}

	// --- Phase 2: Disconnect ---
	conn1.Close(websocket.StatusNormalClosure, "done")
	time.Sleep(300 * time.Millisecond)

	if reg.ProviderCount() != 0 {
		t.Fatalf("provider count after disconnect = %d, want 0", reg.ProviderCount())
	}

	// --- Phase 3: Reconnect with a new connection ---
	conn2 := testkit.ConnectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn2.Close(websocket.StatusNormalClosure, "")

	// Set trust level on the new provider.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	// Before handling the challenge, the provider should NOT be routable
	// because LastChallengeVerified is zero.
	p2 := testkit.FindRoutableProvider(reg, model)
	if p2 != nil {
		t.Fatal("provider should NOT be routable before passing challenge after reconnect")
	}

	// Handle the new challenge.
	challengeHandled2 := make(chan struct{})
	go func() {
		defer close(challengeHandled2)
		for {
			_, data, err := conn2.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				resp := testkit.MakeValidChallengeResponse(data, pubKey)
				conn2.Write(ctx, websocket.MessageText, resp)
				return
			}
		}
	}()

	select {
	case <-challengeHandled2:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for second challenge")
	}

	time.Sleep(200 * time.Millisecond)

	// Now provider should be routable again.
	p3 := testkit.FindRoutableProvider(reg, model)
	if p3 == nil {
		t.Fatal("provider should be routable after passing challenge on reconnect")
	}
}

// TestIntegration_ChallengeFailureBlocksRouting verifies that a provider
// responding with wrong nonces gets marked untrusted after registry.MaxFailedChallenges.
func TestIntegration_ChallengeFailureBlocksRouting(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	srv.SetChallengeInterval(200 * time.Millisecond)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testkit.PublicKeyB64()
	model := "fail-challenge-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	conn := testkit.ConnectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle first challenge correctly so the provider becomes routable.
	firstHandled := make(chan struct{})
	go func() {
		defer close(firstHandled)
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
				resp := testkit.MakeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				return
			}
		}
	}()

	select {
	case <-firstHandled:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for first challenge")
	}

	time.Sleep(200 * time.Millisecond)

	// Set trust level.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	// Verify routable after first challenge.
	if p := testkit.FindRoutableProvider(reg, model); p == nil {
		t.Fatal("provider should be routable after first challenge")
	}

	// Now respond to the next registry.MaxFailedChallenges challenges with wrong nonces.
	failCount := 0
	failsDone := make(chan struct{})
	go func() {
		defer close(failsDone)
		for failCount < registry.MaxFailedChallenges {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				resp := testkit.MakeInvalidChallengeResponse(data)
				conn.Write(ctx, websocket.MessageText, resp)
				failCount++
			}
		}
	}()

	select {
	case <-failsDone:
	case <-time.After(10 * time.Second):
		t.Fatalf("timed out waiting for %d failed challenges, got %d", registry.MaxFailedChallenges, failCount)
	}

	// Wait for the last failure to be processed.
	time.Sleep(500 * time.Millisecond)

	// Provider should be untrusted and NOT routable.
	p := testkit.FindProviderByModel(reg, model)
	if p != nil {
		p.Mu().Lock()
		status := p.Status
		p.Mu().Unlock()
		if status != registry.StatusUntrusted {
			t.Errorf("provider status = %v, want untrusted", status)
		}
	}
	if found := testkit.FindRoutableProvider(reg, model); found != nil {
		t.Error("untrusted provider should not be routable")
	}
}
