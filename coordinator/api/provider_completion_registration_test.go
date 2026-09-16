package api

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

func TestProviderCompletionBeforeRegistrationIsIgnored(t *testing.T) {
	srv, reg, _, ts := setupTestServer(t)
	defer srv.Close()
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// No pending request can belong to this connection yet. An early terminal
	// must be ignored like the other inference frames, without ending the loop.
	for _, message := range []any{
		protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: "unregistered-completion",
			Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20},
		},
		protocol.RegisterMessage{
			Type:     protocol.TypeRegister,
			Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
			Models:   []protocol.ModelInfo{{ID: "completion-registration-model", ModelType: "chat"}},
			Backend:  "mlx-swift",
		},
	} {
		data, err := json.Marshal(message)
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatal(err)
		}
	}

	// The initial challenge is emitted only after registration finishes. It
	// proves the same WebSocket survived the early completion without sleeps.
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("registration after early completion failed: %v", err)
	}
	var challenge protocol.AttestationChallengeMessage
	if err := json.Unmarshal(data, &challenge); err != nil {
		t.Fatal(err)
	}
	if challenge.Type != protocol.TypeAttestationChallenge || challenge.Nonce == "" {
		t.Fatalf("expected initial attestation challenge, got %s", data)
	}
	if got := reg.ProviderCount(); got != 1 {
		t.Fatalf("registered provider count = %d, want 1", got)
	}
}
