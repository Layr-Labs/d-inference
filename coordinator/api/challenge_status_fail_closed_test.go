package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

// Every Swift provider signs the canonical status and reports Secure Boot in
// every challenge response, so for an attested provider an omitted
// status_signature or secure_boot_enabled fails the challenge instead of being
// accepted as advisory. These tests drive the real WebSocket path: an attested
// registration, the coordinator's first challenge, and the provider's reply.

// challengeOverWebSocket registers an attested provider over /ws/provider,
// answers the first attestation challenge with the raw JSON that reply builds,
// and returns the provider once the coordinator has processed the answer.
func challengeOverWebSocket(t *testing.T, model string, reply func(challenge protocol.AttestationChallengeMessage, pubKey string) map[string]any) *registry.Provider {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv := NewServer(reg, memory.NewMemory(store.Config{AdminKey: "test-key"}), ServerConfig{}, logger)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "") })

	pubKey := testPublicKeyB64()
	regData, _ := json.Marshal(protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		Attestation:             createTestAttestationJSON(t, pubKey),
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("register: %v", err)
	}

	var challenge protocol.AttestationChallengeMessage
	for challenge.Type != protocol.TypeAttestationChallenge {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("did not receive attestation challenge: %v", err)
		}
		challenge = protocol.AttestationChallengeMessage{}
		_ = json.Unmarshal(data, &challenge)
	}

	p := findProviderByModel(reg, model)
	if p == nil {
		t.Fatal("provider not registered")
	}
	// Registration already stamps a verification time; the answer to this
	// challenge either restamps it later or fails and clears it.
	p.Mu().Lock()
	before := p.LastChallengeVerified
	p.Mu().Unlock()

	respData, _ := json.Marshal(reply(challenge, pubKey))
	if err := conn.Write(ctx, websocket.MessageText, respData); err != nil {
		t.Fatalf("write challenge response: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		p.Mu().Lock()
		done := p.LastChallengeVerified.After(before) || p.FailedChallenges > 0
		p.Mu().Unlock()
		if done {
			return p
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("challenge response was never processed")
	return nil
}

// currentChallengeResponse is the response a current provider sends: every
// posture field reported and the canonical status signed.
func currentChallengeResponse(challenge protocol.AttestationChallengeMessage, pubKey string) protocol.AttestationResponseMessage {
	sip, secureBoot, rdmaDisabled := true, true, true
	resp := protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             challenge.Nonce,
		Signature:         testChallengeSignature(challenge.Nonce, challenge.Timestamp, pubKey),
		PublicKey:         pubKey,
		SIPEnabled:        &sip,
		SecureBootEnabled: &secureBoot,
		RDMADisabled:      &rdmaDisabled,
	}
	resp.StatusSignature = testResponseStatusSignature(challenge.Nonce, challenge.Timestamp, pubKey, &resp)
	return resp
}

func responseJSON(t *testing.T, resp protocol.AttestationResponseMessage) map[string]any {
	t.Helper()
	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	return raw
}

func assertChallengeVerified(t *testing.T, p *registry.Provider) {
	t.Helper()
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.LastChallengeVerified.IsZero() || p.FailedChallenges != 0 || p.Status == registry.StatusUntrusted {
		t.Fatalf("challenge verified=%v failed=%d status=%s, want verified with no failures",
			!p.LastChallengeVerified.IsZero(), p.FailedChallenges, p.Status)
	}
}

func assertChallengeFailed(t *testing.T, p *registry.Provider) {
	t.Helper()
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if !p.LastChallengeVerified.IsZero() || p.FailedChallenges == 0 {
		t.Fatalf("challenge verified=%v failed=%d, want a failed challenge",
			!p.LastChallengeVerified.IsZero(), p.FailedChallenges)
	}
}

func TestChallengeCurrentSignedStatusPasses(t *testing.T) {
	p := challengeOverWebSocket(t, "signed-status-model", func(c protocol.AttestationChallengeMessage, pubKey string) map[string]any {
		return responseJSON(t, currentChallengeResponse(c, pubKey))
	})
	assertChallengeVerified(t, p)
}

func TestChallengeMissingStatusSignatureFails(t *testing.T) {
	for name, strip := range map[string]func(map[string]any){
		"absent": func(raw map[string]any) { delete(raw, "status_signature") },
		"empty":  func(raw map[string]any) { raw["status_signature"] = "" },
	} {
		t.Run(name, func(t *testing.T) {
			p := challengeOverWebSocket(t, "unsigned-status-"+name, func(c protocol.AttestationChallengeMessage, pubKey string) map[string]any {
				raw := responseJSON(t, currentChallengeResponse(c, pubKey))
				strip(raw)
				return raw
			})
			assertChallengeFailed(t, p)
		})
	}
}

func TestChallengeMissingSecureBootFails(t *testing.T) {
	p := challengeOverWebSocket(t, "missing-secure-boot-model", func(c protocol.AttestationChallengeMessage, pubKey string) map[string]any {
		resp := currentChallengeResponse(c, pubKey)
		// Sign the status as sent, so only the omitted field can fail it.
		resp.SecureBootEnabled = nil
		resp.StatusSignature = testResponseStatusSignature(c.Nonce, c.Timestamp, pubKey, &resp)
		raw := responseJSON(t, resp)
		if _, present := raw["secure_boot_enabled"]; present {
			t.Fatal("fixture still sends secure_boot_enabled")
		}
		return raw
	})
	assertChallengeFailed(t, p)
}
