package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/dginf/coordinator/internal/protocol"
	"github.com/dginf/coordinator/internal/registry"
	"github.com/dginf/coordinator/internal/store"
	"nhooyr.io/websocket"
)

func TestProviderWebSocketConnect(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Send register.
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models: []protocol.ModelInfo{
			{ID: "test-model", SizeBytes: 1000, ModelType: "test", Quantization: "4bit"},
		},
		Backend: "test",
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Wait for registration.
	time.Sleep(100 * time.Millisecond)

	if reg.ProviderCount() != 1 {
		t.Errorf("provider count = %d, want 1", reg.ProviderCount())
	}

	// Send heartbeat.
	hbMsg := protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{RequestsServed: 1, TokensGenerated: 100},
	}
	hbData, _ := json.Marshal(hbMsg)
	if err := conn.Write(ctx, websocket.MessageText, hbData); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}

	time.Sleep(100 * time.Millisecond)

	// Close connection and verify disconnect.
	conn.Close(websocket.StatusNormalClosure, "done")
	time.Sleep(200 * time.Millisecond)

	if reg.ProviderCount() != 0 {
		t.Errorf("provider count after disconnect = %d, want 0", reg.ProviderCount())
	}
}

func TestProviderWebSocketMultiple(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"

	// Connect two providers.
	for i := 0; i < 2; i++ {
		conn, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("websocket dial %d: %v", i, err)
		}
		defer conn.Close(websocket.StatusNormalClosure, "")

		regMsg := protocol.RegisterMessage{
			Type:     protocol.TypeRegister,
			Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
			Models:   []protocol.ModelInfo{{ID: "shared-model", ModelType: "test", Quantization: "4bit"}},
			Backend:  "test",
		}
		regData, _ := json.Marshal(regMsg)
		conn.Write(ctx, websocket.MessageText, regData)
	}

	time.Sleep(200 * time.Millisecond)

	if reg.ProviderCount() != 2 {
		t.Errorf("provider count = %d, want 2", reg.ProviderCount())
	}

	// Upgrade both providers to hardware trust for routing eligibility.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	models := reg.ListModels()
	if len(models) != 1 {
		t.Fatalf("models = %d, want 1 (deduplicated)", len(models))
	}
	if models[0].Providers != 2 {
		t.Errorf("providers for model = %d, want 2", models[0].Providers)
	}
}

func TestProviderInferenceError(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Register (with public key — encryption is mandatory).
	regMsg := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "error-model", ModelType: "test", Quantization: "4bit"}},
		Backend:   "test",
		PublicKey: "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	// Upgrade provider to hardware trust for routing.
	p := findProviderByModel(reg, "error-model")
	if p != nil {
		reg.SetTrustLevel(p.ID, registry.TrustHardware)
		reg.RecordChallengeSuccess(p.ID)
	}

	// Provider goroutine — handle challenge then respond with error.
	go func() {
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]interface{}
			if err := json.Unmarshal(data, &raw); err == nil {
				if raw["type"] == protocol.TypeAttestationChallenge {
					resp := protocol.AttestationResponseMessage{
						Type: protocol.TypeAttestationResponse, Nonce: raw["nonce"].(string),
						PublicKey: "dummy", Signature: "dummy",
					}
					respData, _ := json.Marshal(resp)
					conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
			}
			json.Unmarshal(data, &inferReq)
			break
		}

		errMsg := protocol.InferenceErrorMessage{
			Type:       protocol.TypeInferenceError,
			RequestID:  inferReq.RequestID,
			Error:      "model not loaded",
			StatusCode: 500,
		}
		errData, _ := json.Marshal(errMsg)
		conn.Write(ctx, websocket.MessageText, errData)
	}()

	// Consumer request.
	chatBody := `{"model":"error-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	httpReq, _ := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")

	resp, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 500 {
		t.Errorf("status = %d, want 500", resp.StatusCode)
	}
}

func newAuthRequest(t *testing.T, ctx context.Context, url, body, key string) (*http.Request, error) {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	return req, nil
}

// --- attestation test helpers ---

type ecdsaSigHelper struct {
	R, S *big.Int
}

func createTestAttestationJSON(t *testing.T, encryptionKey string) json.RawMessage {
	t.Helper()

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	// Marshal public key as uncompressed point (65 bytes: 0x04 || X || Y)
	xBytes := privKey.PublicKey.X.Bytes()
	yBytes := privKey.PublicKey.Y.Bytes()
	raw := make([]byte, 65)
	raw[0] = 0x04
	copy(raw[1+32-len(xBytes):33], xBytes)
	copy(raw[33+32-len(yBytes):65], yBytes)

	pubKeyB64 := base64.StdEncoding.EncodeToString(raw)

	// Build attestation blob as sorted-key map
	blobMap := map[string]interface{}{
		"authenticatedRootEnabled": true,
		"chipName":                 "Apple M3 Max",
		"hardwareModel":            "Mac15,8",
		"osVersion":                "15.3.0",
		"publicKey":                pubKeyB64,
		"rdmaDisabled":             true,
		"secureBootEnabled":        true,
		"secureEnclaveAvailable":   true,
		"sipEnabled":               true,
		"timestamp":                time.Now().UTC().Format(time.RFC3339),
	}
	if encryptionKey != "" {
		blobMap["encryptionPublicKey"] = encryptionKey
	}

	blobJSON, err := json.Marshal(blobMap)
	if err != nil {
		t.Fatal(err)
	}

	// Sign
	hash := sha256.Sum256(blobJSON)
	r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	sigDER, err := asn1.Marshal(ecdsaSigHelper{R: r, S: s})
	if err != nil {
		t.Fatal(err)
	}

	// Build SignedAttestation
	signed := map[string]interface{}{
		"attestation": json.RawMessage(blobJSON),
		"signature":   base64.StdEncoding.EncodeToString(sigDER),
	}

	signedJSON, err := json.Marshal(signed)
	if err != nil {
		t.Fatal(err)
	}

	return signedJSON
}

// TestProviderRegistrationWithValidAttestation verifies that a provider
// with a valid Secure Enclave attestation is marked as attested.
func TestProviderRegistrationWithValidAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	attestationJSON := createTestAttestationJSON(t, "")

	regMsg := protocol.RegisterMessage{
		Type:        protocol.TypeRegister,
		Hardware:    protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:      []protocol.ModelInfo{{ID: "attested-model", ModelType: "test", Quantization: "4bit"}},
		Backend:     "test",
		Attestation: attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	if reg.ProviderCount() != 1 {
		t.Fatalf("provider count = %d, want 1", reg.ProviderCount())
	}

	// Upgrade to hardware trust (simulates MDM verification completing).
	p := findProviderByModel(reg, "attested-model")
	if p != nil {
		reg.SetTrustLevel(p.ID, registry.TrustHardware)
		reg.RecordChallengeSuccess(p.ID)
	}

	models := reg.ListModels()
	if len(models) != 1 {
		t.Fatalf("models = %d, want 1", len(models))
	}
	if models[0].AttestedProviders != 1 {
		t.Errorf("attested_providers = %d, want 1", models[0].AttestedProviders)
	}
}

// TestProviderRegistrationWithInvalidAttestation verifies that a provider
// with an invalid attestation is still registered but not marked as attested.
func TestProviderRegistrationWithInvalidAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Invalid attestation: garbage JSON that won't verify
	invalidAttestation := json.RawMessage(`{"attestation":{"chipName":"Fake","hardwareModel":"Bad","osVersion":"0","publicKey":"dGVzdA==","secureBootEnabled":true,"secureEnclaveAvailable":true,"sipEnabled":true,"timestamp":"2025-01-01T00:00:00Z"},"signature":"YmFkc2ln"}`)

	regMsg := protocol.RegisterMessage{
		Type:        protocol.TypeRegister,
		Hardware:    protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:      []protocol.ModelInfo{{ID: "unattested-model", ModelType: "test", Quantization: "4bit"}},
		Backend:     "test",
		Attestation: invalidAttestation,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	// Provider should still be registered but not routable (no hardware trust).
	if reg.ProviderCount() != 1 {
		t.Fatalf("provider count = %d, want 1", reg.ProviderCount())
	}

	// Without hardware trust, models should not be listed.
	models := reg.ListModels()
	if len(models) != 0 {
		t.Fatalf("models = %d, want 0 (invalid attestation, no hardware trust)", len(models))
	}
}

// TestProviderRegistrationWithoutAttestation verifies that a provider
// without an attestation still works in Open Mode.
func TestProviderRegistrationWithoutAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "open-model", ModelType: "test", Quantization: "4bit"}},
		Backend:  "test",
		// No attestation — Open Mode
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	if reg.ProviderCount() != 1 {
		t.Fatalf("provider count = %d, want 1", reg.ProviderCount())
	}

	// Without attestation, provider has no hardware trust and should not be listed.
	models := reg.ListModels()
	if len(models) != 0 {
		t.Fatalf("models = %d, want 0 (no attestation, no hardware trust)", len(models))
	}
}

// TestListModelsWithAttestationInfo verifies that /v1/models includes
// attestation metadata.
func TestListModelsWithAttestationInfo(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"

	// Register an attested provider
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	attestationJSON := createTestAttestationJSON(t, "")
	regMsg := protocol.RegisterMessage{
		Type:        protocol.TypeRegister,
		Hardware:    protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:      []protocol.ModelInfo{{ID: "attested-model", ModelType: "test", Quantization: "4bit"}},
		Backend:     "test",
		Attestation: attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	// Upgrade to hardware trust for model listing.
	p := findProviderByModel(reg, "attested-model")
	if p != nil {
		reg.SetTrustLevel(p.ID, registry.TrustHardware)
		reg.RecordChallengeSuccess(p.ID)
	}

	// Check /v1/models
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var body map[string]any
	json.Unmarshal(w.Body.Bytes(), &body)
	data := body["data"].([]any)
	if len(data) != 1 {
		t.Fatalf("models = %d, want 1", len(data))
	}

	model := data[0].(map[string]any)
	metadata := model["metadata"].(map[string]any)

	attestedProviders := metadata["attested_providers"].(float64)
	if attestedProviders != 1 {
		t.Errorf("attested_providers = %v, want 1", attestedProviders)
	}

	attestation := metadata["attestation"].(map[string]any)
	if attestation["secure_enclave"] != true {
		t.Errorf("secure_enclave = %v, want true", attestation["secure_enclave"])
	}
	if attestation["sip_enabled"] != true {
		t.Errorf("sip_enabled = %v, want true", attestation["sip_enabled"])
	}
	if attestation["secure_boot"] != true {
		t.Errorf("secure_boot = %v, want true", attestation["secure_boot"])
	}
}

// TestChallengeResponseSuccess tests the full challenge-response flow:
// coordinator sends challenge, provider responds, verification passes.
func TestChallengeResponseSuccess(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	// Use a very short challenge interval for testing.
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Register with a public key.
	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "challenge-model", ModelType: "test", Quantization: "4bit"}},
		Backend:   "test",
		PublicKey: pubKey,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	// Wait for the attestation challenge to arrive.
	challengeReceived := false
	for i := 0; i < 20; i++ {
		readCtx, readCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		_, data, err := conn.Read(readCtx)
		readCancel()
		if err != nil {
			continue
		}

		var envelope struct {
			Type string `json:"type"`
		}
		json.Unmarshal(data, &envelope)

		if envelope.Type == protocol.TypeAttestationChallenge {
			challengeReceived = true

			// Parse the challenge.
			var challenge protocol.AttestationChallengeMessage
			json.Unmarshal(data, &challenge)

			// Respond with the expected format.
			response := protocol.AttestationResponseMessage{
				Type:      protocol.TypeAttestationResponse,
				Nonce:     challenge.Nonce,
				Signature: "dGVzdHNpZ25hdHVyZQ==",
				PublicKey: pubKey,
			}
			respData, _ := json.Marshal(response)
			conn.Write(ctx, websocket.MessageText, respData)
			break
		}
	}

	if !challengeReceived {
		t.Fatal("did not receive attestation challenge")
	}

	// Wait for verification to complete.
	time.Sleep(200 * time.Millisecond)

	// Verify provider is still online (not untrusted).
	p := findProviderByModel(reg, "challenge-model")
	if p == nil {
		t.Fatal("provider not found")
	}
	if p.Status == registry.StatusUntrusted {
		t.Error("provider should not be untrusted after successful challenge")
	}
}

// TestChallengeResponseWrongKey tests that a response with wrong public key fails.
func TestChallengeResponseWrongKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "wrongkey-model", ModelType: "test", Quantization: "4bit"}},
		Backend:   "test",
		PublicKey: "Y29ycmVjdGtleQ==",
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	// Answer challenges with the wrong public key repeatedly.
	// We need MaxFailedChallenges (3) failures for the provider to be marked untrusted.
	failCount := 0
	for failCount < MaxFailedChallenges {
		readCtx, readCancel := context.WithTimeout(ctx, 2*time.Second)
		_, data, err := conn.Read(readCtx)
		readCancel()
		if err != nil {
			continue
		}

		var envelope struct {
			Type string `json:"type"`
		}
		json.Unmarshal(data, &envelope)

		if envelope.Type == protocol.TypeAttestationChallenge {
			var challenge protocol.AttestationChallengeMessage
			json.Unmarshal(data, &challenge)

			response := protocol.AttestationResponseMessage{
				Type:      protocol.TypeAttestationResponse,
				Nonce:     challenge.Nonce,
				Signature: "c2lnbmF0dXJl",
				PublicKey: "d3Jvbmdrb3k=", // wrong key
			}
			respData, _ := json.Marshal(response)
			conn.Write(ctx, websocket.MessageText, respData)
			failCount++
		}
	}

	// Wait for the last failure to be processed and provider marked untrusted.
	time.Sleep(500 * time.Millisecond)

	// The provider should still be in the registry (just untrusted).
	// We can't use findProviderByModel because it skips untrusted providers.
	// Instead check directly via GetProvider — but we don't know the ID.
	// Verify the model is no longer available (untrusted providers are excluded).
	models := reg.ListModels()
	for _, m := range models {
		if m.ID == "wrongkey-model" {
			t.Error("wrongkey-model should not be listed after provider marked untrusted")
		}
	}
}

// TestTrustLevelInResponseHeaders verifies that X-Provider-Trust-Level header
// is included in inference responses.
func TestTrustLevelInResponseHeaders(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	attestationJSON := createTestAttestationJSON(t, "")
	regMsg := protocol.RegisterMessage{
		Type:        protocol.TypeRegister,
		Hardware:    protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:      []protocol.ModelInfo{{ID: "trust-model", ModelType: "test", Quantization: "4bit"}},
		Backend:     "test",
		PublicKey:   "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		Attestation: attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	// Provider goroutine — handle challenge then respond with completion.
	go func() {
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]interface{}
			if err := json.Unmarshal(data, &raw); err == nil {
				if raw["type"] == protocol.TypeAttestationChallenge {
					resp := protocol.AttestationResponseMessage{
						Type: protocol.TypeAttestationResponse, Nonce: raw["nonce"].(string),
						PublicKey: "dummy", Signature: "dummy",
					}
					respData, _ := json.Marshal(resp)
					conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
			}
			json.Unmarshal(data, &inferReq)
			break
		}

		chunk := protocol.InferenceResponseChunkMessage{
			Type:      protocol.TypeInferenceResponseChunk,
			RequestID: inferReq.RequestID,
			Data:      `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}` + "\n\n",
		}
		chunkData, _ := json.Marshal(chunk)
		conn.Write(ctx, websocket.MessageText, chunkData)

		complete := protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: inferReq.RequestID,
			Usage:     protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1},
		}
		completeData, _ := json.Marshal(complete)
		conn.Write(ctx, websocket.MessageText, completeData)
	}()

	// Upgrade provider to hardware trust so it's eligible for routing.
	p := findProviderByModel(reg, "trust-model")
	if p != nil {
		reg.SetTrustLevel(p.ID, registry.TrustHardware)
		reg.RecordChallengeSuccess(p.ID)
	}

	chatBody := `{"model":"trust-model","messages":[{"role":"user","content":"hi"}],"stream":true}`
	httpReq, _ := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
	resp, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}

	trustLevel := resp.Header.Get("X-Provider-Trust-Level")
	if trustLevel != "hardware" {
		t.Errorf("X-Provider-Trust-Level = %q, want hardware", trustLevel)
	}

	attested := resp.Header.Get("X-Provider-Attested")
	if attested != "true" {
		t.Errorf("X-Provider-Attested = %q, want true", attested)
	}
}

// TestTrustLevelInModelsList verifies that /v1/models includes trust_level.
func TestTrustLevelInModelsList(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	attestationJSON := createTestAttestationJSON(t, "")
	regMsg := protocol.RegisterMessage{
		Type:        protocol.TypeRegister,
		Hardware:    protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:      []protocol.ModelInfo{{ID: "trust-list-model", ModelType: "test", Quantization: "4bit"}},
		Backend:     "test",
		Attestation: attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(200 * time.Millisecond)

	// Upgrade provider to hardware trust so it appears in model list.
	// Use thread-safe setter to avoid racing with the WebSocket goroutine.
	p := findProviderByModel(reg, "trust-list-model")
	if p != nil {
		reg.SetTrustLevel(p.ID, registry.TrustHardware)
		reg.RecordChallengeSuccess(p.ID)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}

	var body map[string]any
	json.Unmarshal(w.Body.Bytes(), &body)
	data := body["data"].([]any)
	if len(data) != 1 {
		t.Fatalf("models = %d, want 1", len(data))
	}

	model := data[0].(map[string]any)
	metadata := model["metadata"].(map[string]any)
	trustLevel := metadata["trust_level"]
	if trustLevel != "hardware" {
		t.Errorf("trust_level = %v, want hardware", trustLevel)
	}
}

// findProviderByModel returns the first provider offering the given model.
func findProviderByModel(reg *registry.Registry, model string) *registry.Provider {
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
