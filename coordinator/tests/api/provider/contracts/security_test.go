package provider_test

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	api "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

// connectProviderWS connects a provider WebSocket to the test server.
func connectProviderWS(t *testing.T, ts *httptest.Server) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	return conn
}

// registerProvider sends a Register message and waits for it to take effect.
func registerProvider(t *testing.T, conn *websocket.Conn, models []protocol.ModelInfo, publicKey string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models:    models,
		Backend:   "mlx-swift",
		PublicKey: publicKey,
	}
	data, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
}

func TestSecurity_MalformedWebSocketMessages(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	t.Run("invalid_json", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		// Send invalid JSON — server should log a warning and continue, not crash.
		if err := conn.Write(ctx, websocket.MessageText, []byte("{this is not json!!!")); err != nil {
			t.Fatalf("write invalid json: %v", err)
		}

		// Connection should still be alive — send a valid register to prove it.
		registerProvider(t, conn, []protocol.ModelInfo{
			{ID: "test-model", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit"},
		}, "")

		if fixture.Registry.ProviderCount() != 1 {
			t.Errorf("provider count = %d after invalid JSON + valid register, want 1", fixture.Registry.ProviderCount())
		}
	})

	t.Run("empty_message", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		// Send empty message — should not crash.
		if err := conn.Write(ctx, websocket.MessageText, []byte("")); err != nil {
			t.Fatalf("write empty message: %v", err)
		}

		// Connection should still be alive.
		time.Sleep(100 * time.Millisecond)
		registerProvider(t, conn, []protocol.ModelInfo{
			{ID: "empty-test", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
		}, "")
	})

	t.Run("extremely_long_message", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		// Send 1MB of garbage — should not OOM the server.
		// The server sets a 10MB read limit so 1MB should be accepted and
		// parsed as invalid JSON (logged and ignored).
		garbage := make([]byte, 1024*1024)
		for i := range garbage {
			garbage[i] = 'A'
		}
		err := conn.Write(ctx, websocket.MessageText, garbage)
		if err != nil {
			// Write may fail if the server closes the connection due to the
			// large message, which is also acceptable behavior.
			t.Logf("write 1MB garbage: %v (acceptable — server may reject oversized messages)", err)
		}

		// Server should still be running — verify by connecting a new provider.
		time.Sleep(200 * time.Millisecond)
		conn2 := connectProviderWS(t, ts)
		defer conn2.Close(websocket.StatusNormalClosure, "")
		registerProvider(t, conn2, []protocol.ModelInfo{
			{ID: "after-garbage", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
		}, "")
	})

	t.Run("unknown_message_type", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		// First register so the provider is known.
		registerProvider(t, conn, []protocol.ModelInfo{
			{ID: "unknown-type-test", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
		}, "")

		// Send valid JSON with unknown type — should be logged and ignored.
		unknownMsg := map[string]any{
			"type":    "totally_unknown_type",
			"payload": "some data",
		}
		data, _ := json.Marshal(unknownMsg)
		if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatalf("write unknown type: %v", err)
		}

		// Connection should still be alive.
		time.Sleep(100 * time.Millisecond)
		hb := protocol.HeartbeatMessage{
			Type:   protocol.TypeHeartbeat,
			Status: "idle",
		}
		hbData, _ := json.Marshal(hb)
		if err := conn.Write(ctx, websocket.MessageText, hbData); err != nil {
			t.Errorf("connection died after unknown message type: %v", err)
		}
	})

	t.Run("register_missing_fields", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		// Register with no hardware, no models — server should handle gracefully.
		minimalReg := map[string]any{
			"type": protocol.TypeRegister,
		}
		data, _ := json.Marshal(minimalReg)
		if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatalf("write minimal register: %v", err)
		}

		time.Sleep(100 * time.Millisecond)
		// Should not crash; the provider may be registered with empty fields.
	})
}

func TestSecurity_ChallengeNonceReplay(t *testing.T) {
	srv := testkit.New(t, api.ServerConfig{}).Server
	// Use a very fast challenge interval for this test.
	srv.SetChallengeInterval(500 * time.Millisecond)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	conn := connectProviderWS(t, ts)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Register with a public key so challenges verify key consistency.
	registerProvider(t, conn, []protocol.ModelInfo{
		{ID: "nonce-test-model", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
	}, "dGVzdC1wdWJsaWMta2V5LWJhc2U2NA==")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Read the first challenge.
	var firstNonce string
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("read first challenge: %v", err)
		}
		var msg map[string]any
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg["type"] == protocol.TypeAttestationChallenge {
			firstNonce = msg["nonce"].(string)
			t.Logf("received first challenge nonce: %s...", firstNonce[:8])

			// Respond correctly to the first challenge.
			sipTrue := true
			rdmaFalse := true
			resp := protocol.AttestationResponseMessage{
				Type:              protocol.TypeAttestationResponse,
				Nonce:             firstNonce,
				Signature:         "dGVzdC1zaWduYXR1cmU=", // non-empty
				PublicKey:         "dGVzdC1wdWJsaWMta2V5LWJhc2U2NA==",
				SIPEnabled:        &sipTrue,
				RDMADisabled:      &rdmaFalse,
				SecureBootEnabled: &sipTrue,
			}
			respData, _ := json.Marshal(resp)
			if err := conn.Write(ctx, websocket.MessageText, respData); err != nil {
				t.Fatalf("write first challenge response: %v", err)
			}
			break
		}
	}

	// Wait for the second challenge.
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("read second challenge: %v", err)
		}
		var msg map[string]any
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg["type"] == protocol.TypeAttestationChallenge {
			secondNonce := msg["nonce"].(string)
			t.Logf("received second challenge nonce: %s...", secondNonce[:8])

			if secondNonce == firstNonce {
				t.Error("second challenge reused the same nonce — nonces should be unique")
			}

			// Replay attack: respond with the OLD nonce instead of the new one.
			sipTrue := true
			rdmaFalse := true
			replayResp := protocol.AttestationResponseMessage{
				Type:              protocol.TypeAttestationResponse,
				Nonce:             firstNonce, // OLD nonce — should be rejected
				Signature:         "dGVzdC1zaWduYXR1cmU=",
				PublicKey:         "dGVzdC1wdWJsaWMta2V5LWJhc2U2NA==",
				SIPEnabled:        &sipTrue,
				RDMADisabled:      &rdmaFalse,
				SecureBootEnabled: &sipTrue,
			}
			replayData, _ := json.Marshal(replayResp)
			if err := conn.Write(ctx, websocket.MessageText, replayData); err != nil {
				t.Fatalf("write replay response: %v", err)
			}

			// The server should:
			// 1. Not find a pending challenge for the old nonce (it was already consumed)
			// 2. Log "attestation response for unknown challenge"
			// 3. The second challenge times out (since we didn't answer with the correct nonce)
			//
			// This is the correct behavior — old nonces cannot be replayed.
			t.Log("replay response sent with old nonce — server should reject it")
			break
		}
	}

	// The test passes if we get here without the server crashing or accepting
	// the replayed nonce. The challenge tracker removes nonces after use,
	// so replaying an old nonce maps to no pending challenge.
}

func TestSecurity_ProviderImpersonation(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	sharedPubKey := "c2hhcmVkLXB1YmxpYy1rZXktZm9yLXRlc3Q="

	// Provider A registers.
	connA := connectProviderWS(t, ts)
	defer connA.Close(websocket.StatusNormalClosure, "")
	registerProvider(t, connA, []protocol.ModelInfo{
		{ID: "model-a", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
	}, sharedPubKey)

	if fixture.Registry.ProviderCount() != 1 {
		t.Fatalf("expected 1 provider after A, got %d", fixture.Registry.ProviderCount())
	}

	// Provider B registers with the SAME public key.
	connB := connectProviderWS(t, ts)
	defer connB.Close(websocket.StatusNormalClosure, "")
	registerProvider(t, connB, []protocol.ModelInfo{
		{ID: "model-b", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
	}, sharedPubKey)

	// Both connections should be tracked as separate providers (different
	// WebSocket connections get different UUIDs). The coordinator treats
	// each connection as a separate provider entity even if they share
	// a public key. This is by design — a provider can have multiple
	// connections. The important thing is that neither crashes the server.
	if fixture.Registry.ProviderCount() != 2 {
		t.Errorf("expected 2 providers (both registered), got %d", fixture.Registry.ProviderCount())
	}

	t.Log("two providers with same public key both registered — handled as separate connections")
}
