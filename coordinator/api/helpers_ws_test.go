package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const providerFixtureTimeout = 5 * time.Second

// providerWSFixture owns one provider WebSocket and synchronizes tests with
// observable coordinator state instead of wall-clock sleeps. Tests may read
// protocol messages directly from Conn after registration has been observed.
type providerWSFixture struct {
	t   *testing.T
	ctx context.Context
	*websocket.Conn
	reg        *registry.Registry
	publicKey  string
	providerID string
	closeOnce  sync.Once
}

// newProviderWSFixture dials, registers, and waits until the registry exposes
// the exact provider identity. Registration does not consume server messages,
// so challenge and inference tests retain full control of the transport.
func newProviderWSFixture(
	t *testing.T,
	ctx context.Context,
	tsURL string,
	reg *registry.Registry,
	regMsg protocol.RegisterMessage,
) *providerWSFixture {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(tsURL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	existingProviderIDs := make(map[string]struct{}, len(reg.ProviderIDs()))
	for _, id := range reg.ProviderIDs() {
		existingProviderIDs[id] = struct{}{}
	}
	f := &providerWSFixture{
		t:         t,
		ctx:       ctx,
		Conn:      conn,
		reg:       reg,
		publicKey: regMsg.PublicKey,
	}
	t.Cleanup(func() {
		f.Close(websocket.StatusNormalClosure, "test cleanup")
	})

	regData, err := json.Marshal(regMsg)
	if err != nil {
		t.Fatalf("marshal register: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	awaitTestCondition(t, ctx, "provider registration", func() bool {
		for _, id := range reg.ProviderIDs() {
			if _, existed := existingProviderIDs[id]; existed {
				continue
			}
			p := reg.GetProvider(id)
			if p != nil && p.PublicKey == regMsg.PublicKey {
				f.providerID = id
				return true
			}
		}
		return false
	})
	return f
}

func newTestProviderWS(
	t *testing.T,
	ctx context.Context,
	tsURL string,
	reg *registry.Registry,
	models []protocol.ModelInfo,
	publicKey string,
	mutate ...func(*protocol.RegisterMessage),
) *providerWSFixture {
	t.Helper()
	regMsg := testProviderRegisterMessage(models, publicKey)
	for _, fn := range mutate {
		fn(&regMsg)
	}
	return newProviderWSFixture(t, ctx, tsURL, reg, regMsg)
}

func testProviderRegisterMessage(models []protocol.ModelInfo, publicKey string) protocol.RegisterMessage {
	return protocol.RegisterMessage{
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
}

func (f *providerWSFixture) WriteJSON(value any) {
	f.t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		f.t.Fatalf("marshal provider message: %v", err)
	}
	if err := f.Conn.Write(f.ctx, websocket.MessageText, data); err != nil {
		f.t.Fatalf("write provider message: %v", err)
	}
}

func (f *providerWSFixture) ReadType(want string) []byte {
	f.t.Helper()
	for {
		_, data, err := f.Conn.Read(f.ctx)
		if err != nil {
			f.t.Fatalf("read provider message %q: %v", want, err)
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &envelope); err == nil && envelope.Type == want {
			return data
		}
	}
}

func (f *providerWSFixture) RespondToChallenge(response func([]byte) []byte) {
	f.t.Helper()
	data := f.ReadType(protocol.TypeAttestationChallenge)
	if err := f.Conn.Write(f.ctx, websocket.MessageText, response(data)); err != nil {
		f.t.Fatalf("write challenge response: %v", err)
	}
}

func (f *providerWSFixture) MakeRoutable(model string) *registry.Provider {
	f.t.Helper()
	f.reg.SetTrustLevel(f.providerID, registry.TrustHardware)
	f.RespondToChallenge(func(data []byte) []byte {
		return makeValidChallengeResponse(data, f.publicKey)
	})
	var provider *registry.Provider
	awaitTestCondition(f.t, f.ctx, "provider routability", func() bool {
		provider = findRoutableProvider(f.reg, model)
		return provider != nil && provider.ID == f.providerID
	})
	return provider
}

func (f *providerWSFixture) AwaitDisconnected() {
	f.t.Helper()
	awaitTestCondition(f.t, context.Background(), "provider disconnect", func() bool {
		return f.reg.GetProvider(f.providerID) == nil
	})
}

func (f *providerWSFixture) Close(status websocket.StatusCode, reason string) {
	f.t.Helper()
	f.closeOnce.Do(func() {
		if err := f.Conn.Close(status, reason); err != nil {
			_ = f.Conn.CloseNow()
		}
	})
	f.AwaitDisconnected()
}

func awaitTestCondition(t *testing.T, ctx context.Context, what string, condition func() bool) {
	t.Helper()
	if condition() {
		return
	}
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	timer := time.NewTimer(providerFixtureTimeout)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			t.Fatalf("waiting for %s: %v", what, ctx.Err())
		case <-timer.C:
			t.Fatalf("timed out waiting for %s", what)
		case <-ticker.C:
			if condition() {
				return
			}
		}
	}
}

// handleProviderMessages reads WebSocket messages in a loop, dispatches
// challenges vs inference requests, and sends responses. It exits when
// the context is cancelled or the connection closes.
func handleProviderMessages(ctx context.Context, t *testing.T, conn *websocket.Conn, handler func(msgType string, data []byte) []byte) {
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
	respData, _ := json.Marshal(resp)
	return respData
}

// makeInvalidChallengeResponse creates a response with the correct nonce
// but a wrong public key. This ensures the response reaches the challenge
// tracker (nonce must match for dispatch) but verification fails.
func makeInvalidChallengeResponse(data []byte) []byte {
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
func findRoutableProvider(reg *registry.Registry, model string) *registry.Provider {
	pr := &registry.PendingRequest{RequestID: "test-route-probe", Model: model, RequestedMaxTokens: 64}
	p, _ := reg.ReserveProviderEx(model, pr)
	if p != nil {
		p.RemovePending(pr.RequestID)
		reg.SetProviderIdle(p.ID)
	}
	return p
}

// connectProvider dials the WebSocket, registers the provider, and returns only
// after the new provider session is observable in the registry.
func connectProvider(
	t *testing.T,
	ctx context.Context,
	tsURL string,
	reg *registry.Registry,
	models []protocol.ModelInfo,
	publicKey string,
) *providerWSFixture {
	t.Helper()
	return newTestProviderWS(t, ctx, tsURL, reg, models, publicKey)
}

// assertProviderRegistrationRejected waits for the server's policy close,
// proving it consumed and rejected the registration without starting a second
// reader or relying on the registry's initially-empty state.
func assertProviderRegistrationRejected(
	t *testing.T,
	ctx context.Context,
	tsURL string,
	reg *registry.Registry,
	models []protocol.ModelInfo,
	publicKey string,
) {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(tsURL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.CloseNow()

	regData, err := json.Marshal(testProviderRegisterMessage(models, publicKey))
	if err != nil {
		t.Fatalf("marshal register: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	for {
		_, _, err := conn.Read(ctx)
		if err == nil {
			continue
		}
		if ctx.Err() != nil {
			t.Fatalf("waiting for registration rejection: %v", ctx.Err())
		}
		if status := websocket.CloseStatus(err); status != websocket.StatusPolicyViolation {
			t.Fatalf("registration close status = %v, want %v: %v", status, websocket.StatusPolicyViolation, err)
		}
		break
	}
	for _, id := range reg.ProviderIDs() {
		if p := reg.GetProvider(id); p != nil && p.PublicKey == publicKey {
			t.Fatalf("rejected provider %q remained registered", id)
		}
	}
}

// connectProviderWithToken dials and registers a provider with an auth token.
func connectProviderWithToken(
	t *testing.T,
	ctx context.Context,
	tsURL string,
	reg *registry.Registry,
	models []protocol.ModelInfo,
	publicKey, authToken string,
) *providerWSFixture {
	t.Helper()
	return newTestProviderWS(t, ctx, tsURL, reg, models, publicKey, func(msg *protocol.RegisterMessage) {
		msg.AuthToken = authToken
	})
}

// sha256Hex computes SHA-256 of a string and returns hex encoding.
// Mirrors the store's internal helper.
func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// connectProviderWithAttestation dials and registers a provider with an
// attestation blob. It waits for attestation verification and same-serial
// deduplication to settle before returning.
func connectProviderWithAttestation(
	t *testing.T,
	ctx context.Context,
	tsURL string,
	reg *registry.Registry,
	models []protocol.ModelInfo,
	publicKey string,
	attestation json.RawMessage,
) *providerWSFixture {
	t.Helper()
	f := newTestProviderWS(t, ctx, tsURL, reg, models, publicKey, func(msg *protocol.RegisterMessage) {
		msg.Attestation = attestation
	})
	awaitTestCondition(t, ctx, "provider attestation verification", func() bool {
		p := reg.GetProvider(f.providerID)
		if p == nil {
			return false
		}
		result := p.GetAttestationResult()
		if result == nil {
			return false
		}
		if result.SerialNumber == "" {
			return true
		}
		matchingID := ""
		for _, id := range reg.ProviderIDs() {
			candidate := reg.GetProvider(id)
			if candidate == nil {
				continue
			}
			candidateResult := candidate.GetAttestationResult()
			if candidateResult == nil || candidateResult.SerialNumber != result.SerialNumber {
				continue
			}
			if matchingID != "" {
				return false
			}
			matchingID = id
		}
		return matchingID == f.providerID
	})
	return f
}

// waitForChallenge is the sole reader until the first attestation challenge
// arrives. It sends a valid response and waits until the registry records that
// exact response, so callers can safely hand read ownership to another loop.
func waitForChallenge(t *testing.T, ctx context.Context, conn *providerWSFixture, pubKey string) {
	t.Helper()
	provider := conn.reg.GetProvider(conn.providerID)
	if provider == nil {
		t.Fatalf("waitForChallenge: provider %q is not registered", conn.providerID)
	}
	previousVerification := provider.GetLastChallengeVerified()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("waitForChallenge: read error: %v", err)
		}
		var env struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &env); err != nil || env.Type != protocol.TypeAttestationChallenge {
			continue
		}
		resp := makeValidChallengeResponse(data, pubKey)
		if err := conn.Write(ctx, websocket.MessageText, resp); err != nil {
			t.Fatalf("waitForChallenge: write error: %v", err)
		}
		awaitTestCondition(t, ctx, "challenge response handling", func() bool {
			return provider.GetLastChallengeVerified().After(previousVerification)
		})
		return
	}
}

// setupTestServer creates a test server with a short challenge interval and
// returns the server, registry, store, and httptest server.
func setupTestServer(t *testing.T) (*Server, *registry.Registry, store.Store, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond
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
