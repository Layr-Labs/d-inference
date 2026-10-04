package inference_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	api "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

// Verification: the coordinator's SSE output for a private text request contains
// only the decrypted content — no raw ciphertext, no session keys, no encrypted
// payloads leak into the consumer-visible HTTP response.
func TestPrivateTextResponseContainsNoEncryptionArtifacts(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)

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

	pubKey := testkit.PublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "leak-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testkit.PrivacyCaps(),
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
				d := testkit.MakeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, d)
				continue
			}
			if raw["type"] == protocol.TypeInferenceRequest {
				var req protocol.InferenceRequestMessage
				json.Unmarshal(data, &req)
				testkit.WriteEncryptedChunk(t, ctx, conn, req, pubKey,
					`data: {"id":"c1","choices":[{"delta":{"content":"verified"}}]}`+"\n\n")
				testkit.WriteEncryptedChunk(t, ctx, conn, req, pubKey,
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
