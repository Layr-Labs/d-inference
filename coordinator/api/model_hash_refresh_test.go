package api

// End-to-end regression for the stale model-hash heal path: a provider whose
// daemon recomputed a model's weight hash (model re-published while running)
// reports the fresh hash in its attestation challenge response, and the
// coordinator must refresh its stored per-model weight hash — otherwise the
// per-model catalog filter keeps judging the provider by the stale
// registration-time value until the next reconnect.

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

func TestChallengeResponseRefreshesStoredModelWeightHashes(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
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

	// Register with a daemon-start (stale) weight hash.
	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models: []protocol.ModelInfo{{
			ID:           "refresh-model",
			SizeBytes:    1000,
			ModelType:    "chat",
			Quantization: "4bit",
			WeightHash:   "stale-hash-from-registration",
		}},
		Backend:   "mlx-swift",
		PublicKey: pubKey,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Answer the first challenge with a valid response carrying a refreshed
	// model hash (the daemon recomputed it at model (re)load).
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
			ModelHashes:       map[string]string{"refresh-model": "fresh-hash-after-reload"},
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

	// The verified response must refresh the stored per-model hash. Read
	// p.Models under the provider lock — it is replaced copy-on-write by
	// UpdateModelWeightHashes on the challenge goroutine.
	storedHash := func() string {
		ids := reg.ProviderIDs()
		if len(ids) != 1 {
			return ""
		}
		p := reg.GetProvider(ids[0])
		if p == nil {
			return ""
		}
		p.Mu().Lock()
		defer p.Mu().Unlock()
		if len(p.Models) != 1 {
			return ""
		}
		return p.Models[0].WeightHash
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if storedHash() == "fresh-hash-after-reload" {
			return // refreshed — pass
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("stored weight hash = %q, want %q (challenge response did not refresh it)",
		storedHash(), "fresh-hash-after-reload")
}
