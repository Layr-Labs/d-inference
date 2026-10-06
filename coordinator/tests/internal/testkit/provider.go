package testkit

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// handleProviderMessages reads WebSocket messages in a loop, dispatches
// challenges vs inference requests, and sends responses. It exits when
// the context is cancelled or the connection closes.
func HandleProviderMessages(ctx context.Context, t testing.TB, conn *websocket.Conn, handler func(msgType string, data []byte) []byte) {
	t.Helper()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &envelope); err != nil {
			continue
		}
		resp := handler(envelope.Type, data)
		if resp != nil {
			if err := conn.Write(ctx, websocket.MessageText, resp); err != nil {
				return
			}
		}
	}
}

// makeValidChallengeResponse creates a valid attestation response for a challenge.
// "Valid" here means: echoed nonce, matching public key, non-empty signature,
// and all security posture fields set to safe values.
func MakeValidChallengeResponse(data []byte, publicKey string) []byte {
	var challenge protocol.AttestationChallengeMessage
	json.Unmarshal(data, &challenge)
	rdmaDisabled := true
	sipEnabled := true
	secureBootEnabled := true
	resp := protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             challenge.Nonce,
		Signature:         ChallengeSignature(challenge.Nonce, challenge.Timestamp, publicKey),
		PublicKey:         publicKey,
		RDMADisabled:      &rdmaDisabled,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
	}
	resp.StatusSignature = ResponseStatusSignature(challenge.Nonce, challenge.Timestamp, publicKey, &resp)
	respData, _ := json.Marshal(resp)
	return respData
}

// makeInvalidChallengeResponse creates a response with the correct nonce
// but a wrong public key. This ensures the response reaches the challenge
// tracker (nonce must match for dispatch) but verification fails.
func MakeInvalidChallengeResponse(data []byte) []byte {
	var challenge protocol.AttestationChallengeMessage
	json.Unmarshal(data, &challenge)
	rdmaDisabled := true
	sipEnabled := true
	secureBootEnabled := true
	resp := protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             challenge.Nonce, // correct nonce so tracker dispatches it
		Signature:         "c2lnbmF0dXJl",
		PublicKey:         "d3Jvbmdfa2V5X21pc21hdGNo", // wrong key, causes verification failure
		RDMADisabled:      &rdmaDisabled,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
	}
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
func FindRoutableProvider(reg *registry.Registry, model string) *registry.Provider {
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
func ConnectProvider(t testing.TB, ctx context.Context, tsURL string, models []protocol.ModelInfo, publicKey string) *websocket.Conn {
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
		PrivacyCapabilities:     PrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	return conn
}

// connectProviderWithToken dials the WebSocket with an auth token.
func ConnectProviderWithToken(t testing.TB, ctx context.Context, tsURL string, models []protocol.ModelInfo, publicKey, authToken string) *websocket.Conn {
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
		PrivacyCapabilities:     PrivacyCaps(),
		AuthToken:               authToken,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	return conn
}

// connectProviderWithAttestation dials the WebSocket, sends a register message
// with an attestation blob (including serial number), and returns the connection.
func ConnectProviderWithAttestation(t testing.TB, ctx context.Context, tsURL string, models []protocol.ModelInfo, publicKey string, attestation json.RawMessage) *websocket.Conn {
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
		Attestation:             attestation,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     PrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(200 * time.Millisecond)
	return conn
}

// waitForChallenge reads from the provider WebSocket until an attestation
// challenge arrives, responds to it validly, and returns. Non-challenge
// messages are discarded.
func WaitForChallenge(t testing.TB, ctx context.Context, conn *websocket.Conn, pubKey string) {
	t.Helper()
	data := ReadAttestationChallenge(t, ctx, conn)
	resp := MakeValidChallengeResponse(data, pubKey)
	if err := conn.Write(ctx, websocket.MessageText, resp); err != nil {
		t.Fatalf("waitForChallenge: write error: %v", err)
	}
}

// readAttestationChallenge observes completed registration without starting an
// asynchronous challenge response that can mutate the state under assertion.
func ReadAttestationChallenge(t testing.TB, ctx context.Context, conn *websocket.Conn) []byte {
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

// makeProviderRoutable sets trust level to hardware and records a challenge
// success for all currently registered providers so they pass routing checks.
func MakeProviderRoutable(reg *registry.Registry) {
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}
}

// findProviderByModel returns the first provider offering the given model.
func FindProviderByModel(reg *registry.Registry, model string) *registry.Provider {
	for _, id := range reg.ProviderIDs() {
		p := reg.GetProvider(id)
		if p == nil {
			continue
		}
		for _, m := range p.Models {
			if m.ID == model {
				return p
			}
		}
	}
	return nil
}
