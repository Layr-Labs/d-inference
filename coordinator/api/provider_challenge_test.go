package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// TestChallengeResponseSuccess tests the full challenge-response flow:
// coordinator sends challenge, provider responds, verification passes.
func TestChallengeResponseSuccess(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	// Use a very short challenge interval for testing.
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	fixture := newProviderWSFixture(t, ctx, ts.URL, reg, protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "challenge-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:   "mlx-swift",
		PublicKey: pubKey,
	})
	defer fixture.Close(websocket.StatusNormalClosure, "")
	fixture.RespondToChallenge(func(data []byte) []byte {
		return makeValidChallengeResponse(data, pubKey)
	})
	p := reg.GetProvider(fixture.providerID)
	awaitTestCondition(t, ctx, "successful challenge verification", func() bool {
		return !p.GetLastChallengeVerified().IsZero()
	})

	// Verify provider is still online (not untrusted).
	if p.GetStatus() == registry.StatusUntrusted {
		t.Error("provider should not be untrusted after successful challenge")
	}
}

// TestChallengeResponseAllowsRDMAEnabled verifies RDMA-enabled providers pass
// the challenge under the registered-buffer RDMA policy. The response also
// carries the retired hypervisor_active field the way a legacy (< v0.6.31)
// provider still sends it — the coordinator must tolerate it on the wire.
func TestChallengeResponseAllowsRDMAEnabled(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	fixture := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "rdma-enabled-model", ModelType: "chat", Quantization: "4bit"}},
		pubKey,
		func(msg *protocol.RegisterMessage) { msg.Backend = registry.BackendMLXSwift })
	defer fixture.Close(websocket.StatusNormalClosure, "")
	fixture.RespondToChallenge(func(data []byte) []byte {
		var challenge protocol.AttestationChallengeMessage
		if err := json.Unmarshal(data, &challenge); err != nil {
			t.Fatalf("unmarshal challenge: %v", err)
		}
		rdmaDisabled := false
		hypervisorActive := false
		sipEnabled := true
		secureBootEnabled := true
		response := protocol.AttestationResponseMessage{
			Type:              protocol.TypeAttestationResponse,
			Nonce:             challenge.Nonce,
			Signature:         testChallengeSignature(challenge.Nonce, challenge.Timestamp, pubKey),
			PublicKey:         pubKey,
			RDMADisabled:      &rdmaDisabled,
			HypervisorActive:  &hypervisorActive,
			SIPEnabled:        &sipEnabled,
			SecureBootEnabled: &secureBootEnabled,
		}
		respData, err := json.Marshal(response)
		if err != nil {
			t.Fatalf("marshal response: %v", err)
		}
		return respData
	})
	p := reg.GetProvider(fixture.providerID)
	awaitTestCondition(t, ctx, "RDMA challenge verification", func() bool {
		return !p.GetLastChallengeVerified().IsZero()
	})

	if p == nil {
		t.Fatal("provider not found")
	}
	if p.GetStatus() == registry.StatusUntrusted {
		t.Error("provider should not be marked untrusted when RDMA is enabled")
	}
	if p.GetLastChallengeVerified().IsZero() {
		t.Fatal("provider should record challenge success when RDMA is enabled")
	}
}

func TestChallengeResponseRequiresBinaryHashWhenPolicyConfigured(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "missing-challenge-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, knownGoodBinaryHashForTest),
	}
	p := reg.Register("provider-1", nil, regMsg)
	srv.verifyProviderAttestation("provider-1", p, regMsg)
	sipEnabled := true
	secureBootEnabled := true
	rdmaDisabled := true
	challengeTimestamp := "2026-04-24T12:00:00Z"

	srv.verifyChallengeResponse("provider-1", p, &pendingChallenge{
		nonce:     "nonce-1",
		timestamp: challengeTimestamp,
	}, &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             "nonce-1",
		Signature:         testChallengeSignature("nonce-1", challengeTimestamp, pubKey),
		PublicKey:         pubKey,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
		RDMADisabled:      &rdmaDisabled,
	})

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if p.FailedChallenges != 1 {
		t.Fatalf("failed challenges = %d, want 1", p.FailedChallenges)
	}
}

func TestChallengeResponseRejectsHashChangedFromRegistrationAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	otherKnownHash := strings.Repeat("f", 64)
	srv.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest, otherKnownHash})
	srv.SetBinaryHashEnforcement(true) // v0.6.0: exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "changed-challenge-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, knownGoodBinaryHashForTest),
	}
	p := reg.Register("provider-1", nil, regMsg)
	srv.verifyProviderAttestation("provider-1", p, regMsg)
	sipEnabled := true
	secureBootEnabled := true
	rdmaDisabled := true
	challengeTimestamp := "2026-04-24T12:00:00Z"

	srv.verifyChallengeResponse("provider-1", p, &pendingChallenge{
		nonce:     "nonce-1",
		timestamp: challengeTimestamp,
	}, &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             "nonce-1",
		Signature:         testChallengeSignature("nonce-1", challengeTimestamp, pubKey),
		PublicKey:         pubKey,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
		RDMADisabled:      &rdmaDisabled,
		BinaryHash:        otherKnownHash,
	})

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if p.FailedChallenges != 1 {
		t.Fatalf("failed challenges = %d, want 1", p.FailedChallenges)
	}
}

func TestChallengeResponseAcceptsKnownBinaryHash(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "known-challenge-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, knownGoodBinaryHashForTest),
	}
	p := reg.Register("provider-1", nil, regMsg)
	srv.verifyProviderAttestation("provider-1", p, regMsg)
	sipEnabled := true
	secureBootEnabled := true
	rdmaDisabled := true
	challengeTimestamp := "2026-04-24T12:00:00Z"

	srv.verifyChallengeResponse("provider-1", p, &pendingChallenge{
		nonce:     "nonce-1",
		timestamp: challengeTimestamp,
	}, &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             "nonce-1",
		Signature:         testChallengeSignature("nonce-1", challengeTimestamp, pubKey),
		PublicKey:         pubKey,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
		RDMADisabled:      &rdmaDisabled,
		BinaryHash:        knownGoodBinaryHashForTest,
	})

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status == registry.StatusUntrusted {
		t.Fatal("provider should not be marked untrusted with a known binary hash")
	}
	if p.FailedChallenges != 0 {
		t.Fatalf("failed challenges = %d, want 0", p.FailedChallenges)
	}
	if p.LastChallengeVerified.IsZero() {
		t.Fatal("provider should record challenge success with a known binary hash")
	}
}

func TestChallengeResponseRejectsMissingSIPStatus(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	fixture := newProviderWSFixture(t, ctx, ts.URL, reg, protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "missing-sip-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:   "mlx-swift",
		PublicKey: pubKey,
	})
	defer fixture.Close(websocket.StatusNormalClosure, "")
	fixture.RespondToChallenge(func(data []byte) []byte {
		var challenge protocol.AttestationChallengeMessage
		if err := json.Unmarshal(data, &challenge); err != nil {
			t.Fatalf("unmarshal challenge: %v", err)
		}
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
		respData, err := json.Marshal(response)
		if err != nil {
			t.Fatalf("marshal response: %v", err)
		}
		return respData
	})
	p := reg.GetProvider(fixture.providerID)
	awaitTestCondition(t, ctx, "missing SIP challenge rejection", func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.FailedChallenges > 0
	})

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

func TestChallengeResponseRejectsUnsignedBinaryHashWhenPolicyConfigured(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	p := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "unsigned-challenge-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	sipEnabled := true
	secureBootEnabled := true
	rdmaDisabled := true

	srv.verifyChallengeResponse("provider-1", p, &pendingChallenge{
		nonce:     "nonce-1",
		timestamp: "2026-04-24T12:00:00Z",
	}, &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             "nonce-1",
		Signature:         "dGVzdHNpZ25hdHVyZQ==",
		PublicKey:         pubKey,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
		RDMADisabled:      &rdmaDisabled,
		BinaryHash:        knownGoodBinaryHashForTest,
	})

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if p.FailedChallenges != 1 {
		t.Fatalf("failed challenges = %d, want 1", p.FailedChallenges)
	}
	if !p.LastChallengeVerified.IsZero() {
		t.Fatal("provider should not record challenge success for an unsigned binary hash")
	}
}

func TestChallengeResponseMissingSIPClearsExistingRoutingEligibility(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	fixture := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "sip-rotation-model", ModelType: "chat", Quantization: "4bit"}},
		pubKey)
	defer fixture.Close(websocket.StatusNormalClosure, "")
	providerID := fixture.providerID
	reg.SetTrustLevel(providerID, registry.TrustHardware)

	readChallenge := func() protocol.AttestationChallengeMessage {
		t.Helper()
		data := fixture.ReadType(protocol.TypeAttestationChallenge)
		var challenge protocol.AttestationChallengeMessage
		if err := json.Unmarshal(data, &challenge); err != nil {
			t.Fatalf("unmarshal challenge: %v", err)
		}
		return challenge
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
		fixture.WriteJSON(response)
	}

	firstChallenge := readChallenge()
	sendChallengeResponse(firstChallenge, true)
	p := reg.GetProvider(providerID)
	awaitTestCondition(t, ctx, "initial SIP challenge verification", func() bool {
		return !p.GetLastChallengeVerified().IsZero() && len(reg.ListModels()) == 1
	})

	if models := reg.ListModels(); len(models) != 1 {
		t.Fatalf("models after valid challenge = %d, want 1", len(models))
	}

	secondChallenge := readChallenge()
	sendChallengeResponse(secondChallenge, false)
	awaitTestCondition(t, ctx, "SIP eligibility removal", func() bool {
		p.Mu().Lock()
		failed := p.FailedChallenges > 0
		p.Mu().Unlock()
		return failed && p.GetLastChallengeVerified().IsZero() && len(reg.ListModels()) == 0
	})

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

func TestProviderBelowMinVersionStaysHiddenFromModelsAfterChallenge(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond
	srv.minProviderVersion = "0.3.9"
	srv.SetRuntimeManifest(&RuntimeManifest{})

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	fixture := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "below-min-model", ModelType: "chat", Quantization: "4bit"}},
		pubKey,
		func(msg *protocol.RegisterMessage) { msg.Version = "0.3.8" })
	defer fixture.Close(websocket.StatusNormalClosure, "")
	reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)

	fixture.RespondToChallenge(func(data []byte) []byte {
		return makeValidChallengeResponse(data, pubKey)
	})
	// The version gate runs while processing the response, before
	// RecordChallengeSuccess. Receiving the next serial challenge proves the
	// first response was consumed without waiting for an impossible success
	// timestamp.
	fixture.ReadType(protocol.TypeAttestationChallenge)

	p := reg.GetProvider(fixture.providerID)
	if p == nil {
		t.Fatal("below-minimum provider was removed from the registry")
	}
	p.Mu().Lock()
	runtimeVerified := p.RuntimeVerified
	p.Mu().Unlock()
	if runtimeVerified {
		t.Fatal("below-minimum provider became runtime verified")
	}
	if !p.GetLastChallengeVerified().IsZero() {
		t.Fatal("below-minimum provider recorded a successful challenge")
	}
	if models := reg.ListModels(); len(models) != 0 {
		t.Fatalf("models after below-min version challenge = %d, want 0", len(models))
	}
}

// TestChallengeResponseWrongKey tests that a response signed by a different
// valid X25519 identity fails after the provider's valid key is registered.
func TestChallengeResponseWrongKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	wrongPubKey := testPublicKeyB64()
	fixture := newProviderWSFixture(t, ctx, ts.URL, reg, protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "wrongkey-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:   "mlx-swift",
		PublicKey: pubKey,
	})
	defer fixture.Close(websocket.StatusNormalClosure, "")

	for range registry.MaxFailedChallenges {
		fixture.RespondToChallenge(func(data []byte) []byte {
			return makeValidChallengeResponse(data, wrongPubKey)
		})
	}

	p := reg.GetProvider(fixture.providerID)
	awaitTestCondition(t, ctx, "wrong-key provider untrust", func() bool {
		return p.GetStatus() == registry.StatusUntrusted
	})
	p.Mu().Lock()
	failedChallenges := p.FailedChallenges
	p.Mu().Unlock()
	if failedChallenges != registry.MaxFailedChallenges {
		t.Fatalf("failed challenges = %d, want %d", failedChallenges, registry.MaxFailedChallenges)
	}

	// Hard-untrusted providers remain connected for diagnostics but are derouted.
	if reg.GetProvider(fixture.providerID) == nil {
		t.Fatal("untrusted provider was removed from registry")
	}
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
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, pubKey)
	fixture := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "trust-model", ModelType: "chat", Quantization: "4bit"}},
		pubKey,
		func(msg *protocol.RegisterMessage) { msg.Attestation = attestationJSON })
	defer fixture.Close(websocket.StatusNormalClosure, "")

	// Provider goroutine — handle challenge then respond with completion.
	go func() {
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := fixture.Conn.Read(ctx)
			if err != nil {
				return
			}
			var raw map[string]interface{}
			if err := json.Unmarshal(data, &raw); err == nil {
				msgType, _ := raw["type"].(string)
				if msgType == protocol.TypeAttestationChallenge {
					respData := makeValidChallengeResponse(data, pubKey)
					fixture.Conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
				if msgType == protocol.TypeRuntimeStatus || msgType == protocol.TypeTrustStatus {
					continue
				}
			}
			json.Unmarshal(data, &inferReq)
			break
		}

		writeEncryptedTestChunk(t, ctx, fixture.Conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}`+"\n\n")

		complete := protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: inferReq.RequestID,
			Usage:     protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1},
		}
		completeData, _ := json.Marshal(complete)
		fixture.Conn.Write(ctx, websocket.MessageText, completeData)
	}()

	// Upgrade provider to hardware trust so it's eligible for routing.
	reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
	reg.RecordChallengeSuccess(fixture.providerID)

	chatBody := `{"model":"trust-model","messages":[{"role":"user","content":"hi"}],"stream":true}`
	httpReq := newAuthRequest(t, ctx, ts.URL+"/v1/chat/completions", chatBody, "test-key")
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
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	attestationJSON := createTestAttestationJSON(t, pubKey)
	fixture := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "trust-list-model", ModelType: "chat", Quantization: "4bit"}},
		pubKey,
		func(msg *protocol.RegisterMessage) { msg.Attestation = attestationJSON })
	defer fixture.Close(websocket.StatusNormalClosure, "")

	reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
	reg.RecordChallengeSuccess(fixture.providerID)

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

// Issue #239: hitting the failure threshold via missed-challenge timeouts marks
// the provider untrusted but *recoverable* (the challenge loop keeps probing it).
func TestHandleChallengeFailureThresholdTransientIsRecoverable(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	p := reg.Register("p1", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})

	for range registry.MaxFailedChallenges {
		srv.handleChallengeFailure("p1", "timeout")
	}

	if p.Status != registry.StatusUntrusted {
		t.Fatalf("status = %q, want %q after %d timeouts", p.Status, registry.StatusUntrusted, registry.MaxFailedChallenges)
	}
	if p.ChallengeShouldStop() {
		t.Error("ChallengeShouldStop = true, want false (timeout-threshold deroute must be recoverable)")
	}
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0", reg.OnlineCount())
	}
}

// handleChallengeFailure returns the running consecutive-failure count, which
// drives the force-reconnect escalation in handleTransientChallengeFailure.
// A provider whose outbound path is wedged heartbeats forever (never evicted)
// while failing every challenge; the count is what lets the coordinator cycle
// the connection. handleTransientChallengeFailure must also tolerate a nil conn.
func TestHandleChallengeFailureReturnsConsecutiveCountAndNilConnSafe(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	reg.Register("p1", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})

	for i := 1; i <= MaxConsecutiveChallengeTimeoutsBeforeReconnect; i++ {
		got := srv.handleChallengeFailure("p1", "timeout")
		if got != i {
			t.Fatalf("handleChallengeFailure call %d returned %d, want %d", i, got, i)
		}
	}

	// A nil conn (e.g. provider already torn down) must not panic even though
	// the count is past the force-reconnect threshold.
	srv.handleTransientChallengeFailure(nil, "p1", "timeout")

	if got := reg.GetProvider("p1"); got == nil || got.Status != registry.StatusUntrusted {
		t.Fatalf("provider should be untrusted after repeated timeouts")
	}
}

// Issue #239: a non-transient reason at the threshold is a hard deroute — the
// challenge loop stops and it cannot self-recover.
func TestHandleChallengeFailureThresholdSecurityIsHard(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	p := reg.Register("p1", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})

	for range registry.MaxFailedChallenges {
		srv.handleChallengeFailure("p1", "nonce mismatch")
	}

	if p.Status != registry.StatusUntrusted {
		t.Fatalf("status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if !p.ChallengeShouldStop() {
		t.Error("ChallengeShouldStop = false, want true (security-threshold deroute must be hard)")
	}
}
