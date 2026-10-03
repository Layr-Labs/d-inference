package inference

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

// makeValidChallengeResponse creates a valid attestation response for a challenge.
// "Valid" here means: echoed nonce, matching public key, non-empty signature,
// and all security posture fields set to safe values.
func makeValidChallengeResponse(data []byte, publicKey string) []byte {
	var challenge protocol.AttestationChallengeMessage
	json.Unmarshal(data, &challenge)
	rdmaDisabled := true
	sipEnabled := true
	secureBootEnabled := true
	resp := protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             challenge.Nonce,
		Signature:         testChallengeSignature(challenge.Nonce, challenge.Timestamp, publicKey),
		PublicKey:         publicKey,
		RDMADisabled:      &rdmaDisabled,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
	}
	resp.StatusSignature = testResponseStatusSignature(challenge.Nonce, challenge.Timestamp, publicKey, &resp)
	respData, _ := json.Marshal(resp)
	return respData
}

// findRoutableProvider selects a provider for model via the PRODUCTION routing
// path (ReserveProviderEx), releases the reserved capacity, and returns the
// selected provider — or nil when no provider can serve the model right now.
// It replaces the removed score-based registry.FindProvider as a routability
// probe in API-layer tests: routing applies the same structural/privacy/trust/
// challenge/capacity gates, so "is this routable?" assertions hold without a
// parallel routing implementation.
func findRoutableProvider(reg *registry.Registry, model string) *registry.Provider {
	pr := &registry.PendingRequest{RequestID: "test-route-probe", Model: model, RequestedMaxTokens: 64}
	p, _ := reg.ReserveProviderEx(model, pr)
	if p != nil {
		p.RemovePending(pr.RequestID)
		reg.SetProviderIdle(p.ID)
	}
	return p
}

// connectProvider dials the WebSocket, sends a register message, and returns
// the connection. It waits briefly for registration to be processed.
func connectProvider(t *testing.T, ctx context.Context, tsURL string, models []protocol.ModelInfo, publicKey string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(tsURL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models:                  models,
		Backend:                 "mlx-swift",
		PublicKey:               publicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	return conn
}

// connectProviderWithToken dials the WebSocket with an auth token.
func connectProviderWithToken(t *testing.T, ctx context.Context, tsURL string, models []protocol.ModelInfo, publicKey, authToken string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(tsURL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models:                  models,
		Backend:                 "mlx-swift",
		PublicKey:               publicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		AuthToken:               authToken,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	return conn
}

// waitForChallenge reads from the provider WebSocket until an attestation
// challenge arrives, responds to it validly, and returns. Non-challenge
// messages are discarded.
func waitForChallenge(t *testing.T, ctx context.Context, conn *websocket.Conn, pubKey string) {
	t.Helper()
	data := readAttestationChallenge(t, ctx, conn)
	resp := makeValidChallengeResponse(data, pubKey)
	if err := conn.Write(ctx, websocket.MessageText, resp); err != nil {
		t.Fatalf("waitForChallenge: write error: %v", err)
	}
}

// readAttestationChallenge observes completed registration without starting an
// asynchronous challenge response that can mutate the state under assertion.
func readAttestationChallenge(t *testing.T, ctx context.Context, conn *websocket.Conn) []byte {
	t.Helper()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("readAttestationChallenge: read error: %v", err)
		}
		var env struct {
			Type string `json:"type"`
		}
		json.Unmarshal(data, &env)
		if env.Type == protocol.TypeAttestationChallenge {
			return data
		}
	}
}

// setupTestServer creates a test server with a short challenge interval and
// returns the server, registry, store, and httptest server.
func setupTestServer(t *testing.T) (*Owner, *registry.Registry, store.Store, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	testComposition(srv).SetChallengeInterval(200 * time.Millisecond)
	ts := httptest.NewServer(srv.Handler())
	return srv, reg, st, ts
}

// makeProviderRoutable sets trust level to hardware and records a challenge
// success for all currently registered providers so they pass routing checks.
func makeProviderRoutable(reg *registry.Registry) {
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}
}
