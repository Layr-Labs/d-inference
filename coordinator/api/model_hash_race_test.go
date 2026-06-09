package api

// Regression tests for the active-model-hash RACE that false-untrusted busy
// dual-model providers in prod.
//
// The challenge response used to be validated by comparing
// resp.ActiveModelHash (the hash of whatever model the PROVIDER considered
// current when it built the response) against the catalog hash of
// provider.CurrentModel (the model the COORDINATOR believed current, from the
// last heartbeat — up to a heartbeat interval stale). On a provider serving
// two models with interleaved traffic, the current model flips between
// heartbeats, so a perfectly correct hash of model B was misread as a
// tampered hash of model A → false "model swap" hard-untrust.
//
// The fix validates the model-keyed resp.ModelHashes map against the catalog
// — exact and race-free — with a membership fallback for legacy responses
// that carry only active_model_hash.

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
	"nhooyr.io/websocket"
)

const (
	gemmaHash  = "a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6"
	gptOSSHash = "61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512"
)

// challengeExchange registers a dual-model provider, makes the coordinator
// believe "model-gemma" is current (via heartbeat), then answers the first
// challenge with the given hash payload. Returns the provider's final status.
func challengeExchange(
	t *testing.T,
	modelHashes map[string]string,
	activeModelHash string,
) registry.ProviderStatus {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	reg.SetModelCatalog([]registry.CatalogEntry{
		{ID: "model-gemma", WeightHash: gemmaHash},
		{ID: "model-gptoss", WeightHash: gptOSSHash},
	})
	srv := NewServer(reg, st, ServerConfig{}, logger)
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
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M2 Ultra", MemoryGB: 128},
		Models: []protocol.ModelInfo{
			{ID: "model-gemma", SizeBytes: 1000, ModelType: "chat", Quantization: "8bit", WeightHash: gemmaHash},
			{ID: "model-gptoss", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit", WeightHash: gptOSSHash},
		},
		Backend:   "mlx-swift",
		PublicKey: pubKey,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Heartbeat: the coordinator's last word is "model-gemma is current".
	active := "model-gemma"
	hb := protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "serving",
		ActiveModel: &active,
	}
	hbData, _ := json.Marshal(hb)
	if err := conn.Write(ctx, websocket.MessageText, hbData); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}

	// Answer the first challenge with the supplied hash payload.
	answered := false
	for range 30 {
		readCtx, readCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		_, data, err := conn.Read(readCtx)
		readCancel()
		if err != nil {
			continue
		}
		var envelope struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(data, &envelope)
		if envelope.Type != protocol.TypeAttestationChallenge {
			continue
		}
		var challenge protocol.AttestationChallengeMessage
		_ = json.Unmarshal(data, &challenge)
		rdmaDisabled := true
		sipEnabled := true
		secureBootEnabled := true
		resp := protocol.AttestationResponseMessage{
			Type:              protocol.TypeAttestationResponse,
			Nonce:             challenge.Nonce,
			Signature:         testChallengeSignature(challenge.Nonce, challenge.Timestamp, pubKey),
			PublicKey:         pubKey,
			RDMADisabled:      &rdmaDisabled,
			SIPEnabled:        &sipEnabled,
			SecureBootEnabled: &secureBootEnabled,
			ActiveModelHash:   activeModelHash,
			ModelHashes:       modelHashes,
		}
		respData, _ := json.Marshal(resp)
		if err := conn.Write(ctx, websocket.MessageText, respData); err != nil {
			t.Fatalf("write challenge response: %v", err)
		}
		answered = true
		break
	}
	if !answered {
		t.Fatal("no attestation challenge received")
	}

	// Give the coordinator time to process, then read the provider's status.
	time.Sleep(300 * time.Millisecond)
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("expected 1 provider, got %d", len(ids))
	}
	p := reg.GetProvider(ids[0])
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.Status
}

// TestChallengeCorrectHashesOfOtherModelDoNotUntrust reproduces the prod race:
// the coordinator believes model-gemma is current (heartbeat), but the
// provider's active model flipped to model-gptoss before it answered — so
// active_model_hash is gptoss's (correct) hash while the coordinator expects
// gemma's. With correct per-model hashes in model_hashes, the provider must
// NOT be untrusted. Fails on the old guess-based check.
func TestChallengeCorrectHashesOfOtherModelDoNotUntrust(t *testing.T) {
	status := challengeExchange(t,
		map[string]string{"model-gemma": gemmaHash, "model-gptoss": gptOSSHash},
		gptOSSHash, // hash of the model the provider ACTUALLY has active
	)
	if status == registry.StatusUntrusted {
		t.Fatal("provider with correct per-model hashes was untrusted (active-model guess race)")
	}
}

// TestChallengeWrongModelHashUntrusts: a genuinely wrong hash for an advertised
// model must still hard-untrust (the security check stays effective).
func TestChallengeWrongModelHashUntrusts(t *testing.T) {
	status := challengeExchange(t,
		map[string]string{"model-gemma": "deadbeef" + gemmaHash[8:], "model-gptoss": gptOSSHash},
		gptOSSHash,
	)
	if status != registry.StatusUntrusted {
		t.Fatalf("provider with tampered model hash was not untrusted (status=%s)", status)
	}
}

// TestChallengeLegacyActiveHashMatchingAnyModelAccepted: legacy responses with
// no model_hashes map are accepted when active_model_hash matches ANY
// advertised model's catalog hash (membership, not the racy current-model guess).
func TestChallengeLegacyActiveHashMatchingAnyModelAccepted(t *testing.T) {
	status := challengeExchange(t, nil, gptOSSHash)
	if status == registry.StatusUntrusted {
		t.Fatal("legacy response with a valid advertised-model hash was untrusted")
	}
}

// TestChallengeLegacyActiveHashMatchingNothingUntrusts: a legacy response whose
// active hash matches no advertised model is still rejected.
func TestChallengeLegacyActiveHashMatchingNothingUntrusts(t *testing.T) {
	status := challengeExchange(t, nil, "deadbeef"+gemmaHash[8:])
	if status != registry.StatusUntrusted {
		t.Fatalf("legacy response with unknown hash was not untrusted (status=%s)", status)
	}
}
