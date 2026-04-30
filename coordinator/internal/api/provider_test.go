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
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/darkbloom/coordinator/internal/attestation"
	"github.com/darkbloom/coordinator/internal/e2e"
	"github.com/darkbloom/coordinator/internal/protocol"
	"github.com/darkbloom/coordinator/internal/registry"
	"github.com/darkbloom/coordinator/internal/store"
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
			{ID: "test-model", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit"},
		},
		Backend: "inprocess-mlx",
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
	for i := range 2 {
		conn, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("websocket dial %d: %v", i, err)
		}
		defer conn.Close(websocket.StatusNormalClosure, "")

		pubKey := testPublicKeyB64()
		regMsg := protocol.RegisterMessage{
			Type:                    protocol.TypeRegister,
			Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
			Models:                  []protocol.ModelInfo{{ID: "shared-model", ModelType: "chat", Quantization: "4bit"}},
			Backend:                 "inprocess-mlx",
			PublicKey:               pubKey,
			EncryptedResponseChunks: true,
			PrivacyCapabilities:     testPrivacyCaps(),
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

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "error-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
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

	// Provider goroutine — handle challenges and always respond with error
	// for inference requests. Loops to handle retry attempts from the coordinator.
	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]interface{}
			if err := json.Unmarshal(data, &raw); err != nil {
				continue
			}
			switch raw["type"] {
			case protocol.TypeAttestationChallenge:
				respData := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, respData)
			case protocol.TypeInferenceRequest:
				reqID, _ := raw["request_id"].(string)
				errMsg := protocol.InferenceErrorMessage{
					Type:       protocol.TypeInferenceError,
					RequestID:  reqID,
					Error:      "model not loaded",
					StatusCode: 500,
				}
				errData, _ := json.Marshal(errMsg)
				conn.Write(ctx, websocket.MessageText, errData)
			}
		}
	}()

	// Consumer request.
	chatBody := `{"model":"error-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	httpReq, _ := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")

	resp, err := ts.Client().Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusInternalServerError {
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

var testAttestationChallengeKeys sync.Map

func registerTestChallengeSigner(encryptionKey string, privKey *ecdsa.PrivateKey) {
	if encryptionKey == "" || privKey == nil {
		return
	}
	testAttestationChallengeKeys.Store(encryptionKey, privKey)
}

func testChallengeSignature(nonce, timestamp, encryptionKey string) string {
	if rawKey, ok := testAttestationChallengeKeys.Load(encryptionKey); ok {
		if privKey, ok := rawKey.(*ecdsa.PrivateKey); ok && privKey != nil {
			hash := sha256.Sum256([]byte(nonce + timestamp))
			r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
			if err == nil {
				if sigDER, err := asn1.Marshal(ecdsaSigHelper{R: r, S: s}); err == nil {
					return base64.StdEncoding.EncodeToString(sigDER)
				}
			}
		}
	}
	return "dGVzdHNpZ25hdHVyZQ=="
}

func rawP256PublicKeyB64ForTest(t *testing.T, pubKey *ecdsa.PublicKey) string {
	t.Helper()
	xBytes := pubKey.X.Bytes()
	yBytes := pubKey.Y.Bytes()
	raw := make([]byte, 64)
	copy(raw[32-len(xBytes):32], xBytes)
	copy(raw[64-len(yBytes):64], yBytes)
	return base64.StdEncoding.EncodeToString(raw)
}

func createTestAttestationJSON(t *testing.T, encryptionKey string) json.RawMessage {
	t.Helper()

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	// Marshal public key as uncompressed point (65 bytes: 0x04 || X || Y)
	xBytes := privKey.X.Bytes()
	yBytes := privKey.Y.Bytes()
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
		registerTestChallengeSigner(encryptionKey, privKey)
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

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, pubKey)

	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "attested-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             attestationJSON,
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
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "unattested-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               testPublicKeyB64(),
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             invalidAttestation,
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
		Models:   []protocol.ModelInfo{{ID: "open-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "inprocess-mlx",
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

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, pubKey)
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "attested-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             attestationJSON,
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

func TestAttestationRejectsMissingEncryptionKeyForRegisteredPublicKey(t *testing.T) {
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

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, "")
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "binding-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(200 * time.Millisecond)

	p := findProviderByModel(reg, "binding-model")
	if p == nil {
		t.Fatal("expected provider to be registered")
	}
	ar := p.GetAttestationResult()
	if ar == nil {
		t.Fatal("expected attestation result to be recorded")
	}
	if ar.Valid {
		t.Fatal("attestation should be invalid when encryptionPublicKey is missing")
	}
	if ar.Error != "attestation missing encryption public key" {
		t.Fatalf("attestation error = %q", ar.Error)
	}
}

func TestAttestationRejectsMismatchedEncryptionKey(t *testing.T) {
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

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, testPublicKeyB64())
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "binding-mismatch-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             attestationJSON,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(200 * time.Millisecond)

	p := findProviderByModel(reg, "binding-mismatch-model")
	if p == nil {
		t.Fatal("expected provider to be registered")
	}
	ar := p.GetAttestationResult()
	if ar == nil {
		t.Fatal("expected attestation result to be recorded")
	}
	if ar.Valid {
		t.Fatal("attestation should be invalid when encryptionPublicKey mismatches")
	}
	if ar.Error != "encryption key mismatch" {
		t.Fatalf("attestation error = %q", ar.Error)
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
		Models:    []protocol.ModelInfo{{ID: "challenge-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:   "inprocess-mlx",
		PublicKey: pubKey,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	// Wait for the attestation challenge to arrive.
	challengeReceived := false
	for range 20 {
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

			respData := makeValidChallengeResponse(data, pubKey)
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

func TestChallengeResponseRejectsMissingSIPStatus(t *testing.T) {
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

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "missing-sip-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:   "inprocess-mlx",
		PublicKey: pubKey,
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	challengeReceived := false
	for range 20 {
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

			var challenge protocol.AttestationChallengeMessage
			json.Unmarshal(data, &challenge)

			rdmaDisabled := true
			secureBootEnabled := true
			response := protocol.AttestationResponseMessage{
				Type:              protocol.TypeAttestationResponse,
				Nonce:             challenge.Nonce,
				Signature:         "dGVzdHNpZ25hdHVyZQ==",
				PublicKey:         pubKey,
				RDMADisabled:      &rdmaDisabled,
				SecureBootEnabled: &secureBootEnabled,
			}
			respData, _ := json.Marshal(response)
			conn.Write(ctx, websocket.MessageText, respData)
			break
		}
	}

	if !challengeReceived {
		t.Fatal("did not receive attestation challenge")
	}

	time.Sleep(200 * time.Millisecond)

	p := findProviderByModel(reg, "missing-sip-model")
	if p == nil {
		t.Fatal("provider not found")
	}
	if !p.GetLastChallengeVerified().IsZero() {
		t.Fatal("provider should not record challenge success when SIP status is omitted")
	}
	if p.GetChallengeVerifiedSIP() {
		t.Fatal("provider should not mark SIP verified when SIP status is omitted")
	}
}

func TestChallengeResponseMissingSIPClearsExistingRoutingEligibility(t *testing.T) {
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

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "sip-rotation-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	var providerID string
	for _, id := range reg.ProviderIDs() {
		providerID = id
	}
	if providerID == "" {
		t.Fatal("provider was not registered")
	}
	reg.SetTrustLevel(providerID, registry.TrustHardware)

	readChallenge := func() protocol.AttestationChallengeMessage {
		t.Helper()
		for range 20 {
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
			if envelope.Type != protocol.TypeAttestationChallenge {
				continue
			}

			var challenge protocol.AttestationChallengeMessage
			json.Unmarshal(data, &challenge)
			return challenge
		}

		t.Fatal("did not receive attestation challenge")
		return protocol.AttestationChallengeMessage{}
	}

	sendChallengeResponse := func(challenge protocol.AttestationChallengeMessage, includeSIP bool) {
		t.Helper()
		rdmaDisabled := true
		secureBootEnabled := true
		response := protocol.AttestationResponseMessage{
			Type:              protocol.TypeAttestationResponse,
			Nonce:             challenge.Nonce,
			Signature:         "dGVzdHNpZ25hdHVyZQ==",
			PublicKey:         pubKey,
			RDMADisabled:      &rdmaDisabled,
			SecureBootEnabled: &secureBootEnabled,
		}
		if includeSIP {
			sipEnabled := true
			response.SIPEnabled = &sipEnabled
		}
		respData, _ := json.Marshal(response)
		conn.Write(ctx, websocket.MessageText, respData)
	}

	firstChallenge := readChallenge()
	sendChallengeResponse(firstChallenge, true)
	time.Sleep(200 * time.Millisecond)

	if models := reg.ListModels(); len(models) != 1 {
		t.Fatalf("models after valid challenge = %d, want 1", len(models))
	}

	secondChallenge := readChallenge()
	sendChallengeResponse(secondChallenge, false)
	time.Sleep(200 * time.Millisecond)

	p := findProviderByModel(reg, "sip-rotation-model")
	if p == nil {
		t.Fatal("provider not found")
	}
	if !p.GetLastChallengeVerified().IsZero() {
		t.Fatal("failed challenge should clear prior challenge freshness")
	}
	if p.GetChallengeVerifiedSIP() {
		t.Fatal("failed challenge should clear prior SIP verification")
	}
	if models := reg.ListModels(); len(models) != 0 {
		t.Fatalf("models after omitted SIP = %d, want 0", len(models))
	}
}

func TestApplyACMETrustRequiresBoundEncryptionAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	msg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "acme-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               testPublicKeyB64(),
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	p := reg.Register("provider-1", nil, msg)
	p.SetAttestationResult(&attestation.VerificationResult{
		Valid: true,
		// Missing EncryptionPublicKey: ACME must not bypass the E2E key binding.
	})

	srv.applyACMETrust("provider-1", p, &ACMEVerificationResult{
		Valid:        true,
		PublicKey:    "acme-public-key",
		SerialNumber: "serial-1",
	})

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if !p.ACMEVerified {
		t.Fatal("ACME verification flag should be recorded")
	}
	if p.TrustLevel == registry.TrustHardware {
		t.Fatal("ACME should not upgrade hardware trust without a bound encryption attestation")
	}
}

func TestApplyACMETrustUpgradesBoundEncryptionAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	attestationKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	acmeKeyB64, err := encodeP256PublicKey(&attestationKey.PublicKey)
	if err != nil {
		t.Fatalf("encodeP256PublicKey: %v", err)
	}

	msg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "acme-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               testPublicKeyB64(),
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	p := reg.Register("provider-1", nil, msg)
	p.SetAttestationResult(&attestation.VerificationResult{
		Valid:               true,
		PublicKey:           rawP256PublicKeyB64ForTest(t, &attestationKey.PublicKey),
		EncryptionPublicKey: msg.PublicKey,
	})

	srv.applyACMETrust("provider-1", p, &ACMEVerificationResult{
		Valid:        true,
		PublicKey:    acmeKeyB64,
		SerialNumber: "serial-1",
	})

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if !p.ACMEVerified {
		t.Fatal("ACME verification flag should be recorded")
	}
	if p.TrustLevel != registry.TrustHardware {
		t.Fatal("ACME should upgrade hardware trust when the attested encryption key is bound")
	}
}

func TestApplyACMETrustRequiresMatchingAttestedSEKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	attestationKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey(attestation): %v", err)
	}
	acmeKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey(acme): %v", err)
	}
	acmeKeyB64, err := encodeP256PublicKey(&acmeKey.PublicKey)
	if err != nil {
		t.Fatalf("encodeP256PublicKey: %v", err)
	}

	msg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "acme-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               testPublicKeyB64(),
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	p := reg.Register("provider-1", nil, msg)
	p.SetAttestationResult(&attestation.VerificationResult{
		Valid:               true,
		PublicKey:           rawP256PublicKeyB64ForTest(t, &attestationKey.PublicKey),
		EncryptionPublicKey: msg.PublicKey,
	})

	srv.applyACMETrust("provider-1", p, &ACMEVerificationResult{
		Valid:        true,
		PublicKey:    acmeKeyB64,
		SerialNumber: "serial-1",
	})

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if !p.ACMEVerified {
		t.Fatal("ACME verification flag should be recorded")
	}
	if p.TrustLevel == registry.TrustHardware {
		t.Fatal("ACME should not upgrade hardware trust when the ACME cert key mismatches attestation")
	}
}

func TestProviderBelowMinVersionStaysHiddenFromModelsAfterChallenge(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond
	srv.minProviderVersion = "0.3.9"
	srv.SetRuntimeManifest(&RuntimeManifest{})

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

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "below-min-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		Version:                 "0.3.8",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	var providerID string
	for _, id := range reg.ProviderIDs() {
		providerID = id
	}
	if providerID == "" {
		t.Fatal("provider was not registered")
	}
	reg.SetTrustLevel(providerID, registry.TrustHardware)

	challengeReceived := false
	for range 20 {
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
		if envelope.Type != protocol.TypeAttestationChallenge {
			continue
		}

		challengeReceived = true
		respData := makeValidChallengeResponse(data, pubKey)
		conn.Write(ctx, websocket.MessageText, respData)
		break
	}

	if !challengeReceived {
		t.Fatal("did not receive attestation challenge")
	}

	time.Sleep(200 * time.Millisecond)

	if models := reg.ListModels(); len(models) != 0 {
		t.Fatalf("models after below-min version challenge = %d, want 0", len(models))
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
		Models:    []protocol.ModelInfo{{ID: "wrongkey-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:   "inprocess-mlx",
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

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, pubKey)
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "trust-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		Attestation:             attestationJSON,
		PrivacyCapabilities:     testPrivacyCaps(),
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
				msgType, _ := raw["type"].(string)
				if msgType == protocol.TypeAttestationChallenge {
					respData := makeValidChallengeResponse(data, pubKey)
					conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
				if msgType == protocol.TypeRuntimeStatus {
					continue
				}
			}
			json.Unmarshal(data, &inferReq)
			break
		}

		writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}`+"\n\n")

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

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, pubKey)
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "trust-list-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             attestationJSON,
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

func TestHandleChunkDecryptsEncryptedTextChunk(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("generate session keys: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:      "req-1",
		Model:          "test-model",
		ChunkCh:        make(chan string, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	provider.AddPending(pr)

	expected := `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"secret"}}]}`
	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{
		RequestID: "req-1",
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: base64.StdEncoding.EncodeToString(sessionKeys.PublicKey[:]),
			Ciphertext:         "",
		},
	}, providerPublicKey, expected)

	srv.handleChunk(provider.ID, provider, &chunk)

	select {
	case got := <-pr.ChunkCh:
		if got != expected {
			t.Fatalf("chunk = %q, want %q", got, expected)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for decrypted chunk")
	}

	select {
	case errMsg := <-pr.ErrorCh:
		t.Fatalf("unexpected error: %+v", errMsg)
	default:
	}
}

func TestHandleChunkRejectsPlaintextTextChunk(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("generate session keys: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:      "req-plain",
		Model:          "test-model",
		ChunkCh:        make(chan string, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	provider.AddPending(pr)

	srv.handleChunk(provider.ID, provider, &protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: pr.RequestID,
		Data:      `data: {"plaintext":true}`,
	})

	select {
	case errMsg, ok := <-pr.ErrorCh:
		if !ok {
			t.Fatal("error channel closed before error was delivered")
		}
		if errMsg.StatusCode != http.StatusBadGateway {
			t.Fatalf("status code = %d, want %d", errMsg.StatusCode, http.StatusBadGateway)
		}
		if errMsg.Error != "provider returned invalid encrypted chunk" {
			t.Fatalf("error = %q", errMsg.Error)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for plaintext chunk rejection")
	}

	if got := reg.GetProvider(provider.ID); got == nil || got.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %v, want %v", got.Status, registry.StatusUntrusted)
	}

	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("pending request still registered after plaintext chunk violation")
	}

	select {
	case chunk, ok := <-pr.ChunkCh:
		if ok {
			t.Fatalf("unexpected chunk delivered: %q", chunk)
		}
	default:
		t.Fatal("chunk channel should be closed after plaintext chunk violation")
	}
}

func TestHandleChunkRejectsMixedPlaintextAndEncryptedTextChunk(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-mixed", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               providerPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("generate session keys: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:      "req-mixed",
		Model:          "test-model",
		ChunkCh:        make(chan string, 1),
		CompleteCh:     make(chan protocol.UsageInfo, 1),
		ErrorCh:        make(chan protocol.InferenceErrorMessage, 1),
		SessionPrivKey: &sessionKeys.PrivateKey,
	}
	provider.AddPending(pr)

	expected := `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"secret"}}]}`
	chunk := testEncryptedChunk(t, protocol.InferenceRequestMessage{
		RequestID: "req-mixed",
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: base64.StdEncoding.EncodeToString(sessionKeys.PublicKey[:]),
			Ciphertext:         "",
		},
	}, providerPublicKey, expected)
	chunk.Data = `data: {"plaintext":"leak"}`

	srv.handleChunk(provider.ID, provider, &chunk)

	select {
	case errMsg := <-pr.ErrorCh:
		if errMsg.StatusCode != http.StatusBadGateway {
			t.Fatalf("status code = %d, want %d", errMsg.StatusCode, http.StatusBadGateway)
		}
		if errMsg.Error != "provider returned invalid encrypted chunk" {
			t.Fatalf("error = %q", errMsg.Error)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for mixed chunk rejection")
	}

	if got := reg.GetProvider(provider.ID); got == nil || got.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %v, want %v", got.Status, registry.StatusUntrusted)
	}
}

// Verification: the coordinator's SSE output for a private text request contains
// only the decrypted content — no raw ciphertext, no session keys, no encrypted
// payloads leak into the consumer-visible HTTP response.
func TestPrivateTextResponseContainsNoEncryptionArtifacts(t *testing.T) {
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

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "leak-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "inprocess-mlx",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]interface{}
			json.Unmarshal(data, &raw)

			if raw["type"] == protocol.TypeAttestationChallenge {
				d := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, d)
				continue
			}
			if raw["type"] == protocol.TypeInferenceRequest {
				var req protocol.InferenceRequestMessage
				json.Unmarshal(data, &req)

				writeEncryptedTestChunk(t, ctx, conn, req, pubKey,
					`data: {"id":"c1","choices":[{"delta":{"content":"verified"}}]}`+"\n\n")
				writeEncryptedTestChunk(t, ctx, conn, req, pubKey,
					"data: [DONE]\n\n")

				complete := protocol.InferenceCompleteMessage{
					Type: protocol.TypeInferenceComplete, RequestID: req.RequestID,
					Usage: protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
				}
				d, _ := json.Marshal(complete)
				conn.Write(ctx, websocket.MessageText, d)
				return
			}
		}
	}()

	chatBody := `{"model":"leak-model","messages":[{"role":"user","content":"secret prompt"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}

	body, _ := io.ReadAll(resp.Body)
	bodyStr := string(body)

	// The consumer-visible response must contain the decrypted text...
	if !strings.Contains(bodyStr, "verified") {
		t.Fatal("response missing decrypted content 'verified'")
	}

	// ...but must NOT contain encryption artifacts.
	for _, banned := range []string{
		"ephemeral_public_key", "ciphertext", "encrypted_data",
		"session_priv_key", "SessionPrivKey",
	} {
		if strings.Contains(bodyStr, banned) {
			t.Fatalf("consumer response leaked encryption artifact: %q", banned)
		}
	}

	// Response headers must not leak provider keys.
	for _, h := range resp.Header {
		for _, v := range h {
			if strings.Contains(v, pubKey) {
				t.Fatal("provider public key leaked in response header")
			}
		}
	}

	<-providerDone
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
