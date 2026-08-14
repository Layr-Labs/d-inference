package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestHandleChunkDecryptsEncryptedTextChunk(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
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
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
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
		if errMsg.Error != "encrypted inference transport failed" {
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
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	providerPublicKey := testPublicKeyB64()
	provider := reg.Register("provider-mixed", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
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
		if errMsg.Error != "encrypted inference transport failed" {
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
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

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
		Backend:                 "mlx-swift",
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
