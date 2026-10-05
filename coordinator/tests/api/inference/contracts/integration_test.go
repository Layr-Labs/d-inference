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
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

// TestIntegration_E2EEncryptionRoundtrip tests that the coordinator's
// encryption can be decrypted by Go code using the same NaCl Box primitives
// that the Swift provider uses.
func TestIntegration_E2EEncryptionRoundtrip(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	srv.SetChallengeInterval(200 * time.Millisecond)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Generate a real provider keypair and cache it so the encrypted chunk helper
	// can emit responses signed by the same provider identity.
	pubKeyB64 := testkit.PublicKeyB64()
	value, ok := testkit.ProviderKeys.
		Load(pubKeyB64)
	if !ok {
		t.Fatalf("missing cached provider keypair for %q", pubKeyB64)
	}
	keypair := value.(testkit.ProviderKeyPair)

	model := "e2e-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	conn := testkit.ConnectProvider(t, ctx, ts.URL, models, pubKeyB64)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle the first challenge so the provider is routable.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Start a goroutine to handle challenges and capture the inference request.
	type inferResult struct {
		decryptedBody []byte
		err           error
	}
	resultCh := make(chan inferResult, 1)

	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				resultCh <- inferResult{err: err}
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			if env.Type == protocol.TypeAttestationChallenge {
				resp := testkit.MakeValidChallengeResponse(data, pubKeyB64)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				// Parse the encrypted body.
				var inferReq struct {
					Type          string `json:"type"`
					RequestID     string `json:"request_id"`
					EncryptedBody *struct {
						EphemeralPublicKey string `json:"ephemeral_public_key"`
						Ciphertext         string `json:"ciphertext"`
					} `json:"encrypted_body"`
				}
				if err := json.Unmarshal(data, &inferReq); err != nil {
					resultCh <- inferResult{err: err}
					return
				}

				if inferReq.EncryptedBody == nil {
					resultCh <- inferResult{err: err}
					return
				}

				// Decrypt using the provider's private key and the e2e package.
				payload := &e2e.EncryptedPayload{
					EphemeralPublicKey: inferReq.EncryptedBody.EphemeralPublicKey,
					Ciphertext:         inferReq.EncryptedBody.Ciphertext,
				}
				decrypted, err := e2e.DecryptWithPrivateKey(payload, keypair.Private)
				resultCh <- inferResult{decryptedBody: decrypted, err: err}
				testkit.WriteEncryptedChunk( // Send back chunks + complete so the consumer handler doesn't hang.
					t, ctx, conn, protocol.InferenceRequestMessage{
						RequestID: inferReq.RequestID,
						EncryptedBody: &protocol.EncryptedPayload{
							EphemeralPublicKey: inferReq.EncryptedBody.EphemeralPublicKey,
							Ciphertext:         inferReq.EncryptedBody.Ciphertext,
						},
					}, pubKeyB64,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}`+"\n\n")

				complete := protocol.InferenceCompleteMessage{
					Type:      protocol.TypeInferenceComplete,
					RequestID: inferReq.RequestID,
					Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
				}
				completeData, _ := json.Marshal(complete)
				conn.Write(ctx, websocket.MessageText, completeData)
				return
			}
		}
	}()

	// Send a consumer request.
	chatBody := `{"model":"e2e-model","messages":[{"role":"user","content":"what is 2+2?"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	// Drain the body to let the provider complete.
	io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}

	// Get the decryption result from the provider goroutine.
	select {
	case result := <-resultCh:
		if result.err != nil {
			t.Fatalf("provider decryption failed: %v", result.err)
		}

		// The decrypted body should be a valid InferenceRequestBody.
		var body protocol.InferenceRequestBody
		if err := json.Unmarshal(result.decryptedBody, &body); err != nil {
			t.Fatalf("unmarshal decrypted body: %v", err)
		}

		if body.Model != "e2e-model" {
			t.Errorf("decrypted model = %q, want %q", body.Model, "e2e-model")
		}
		if len(body.Messages) != 1 {
			t.Fatalf("decrypted messages count = %d, want 1", len(body.Messages))
		}
		if body.Messages[0].Content != "what is 2+2?" {
			t.Errorf("decrypted content = %q, want %q", body.Messages[0].Content, "what is 2+2?")
		}
		if body.Messages[0].Role != "user" {
			t.Errorf("decrypted role = %q, want %q", body.Messages[0].Role, "user")
		}
		if !body.Stream {
			t.Error("decrypted stream = false, want true")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for provider decryption result")
	}
}

// TestIntegration_RequestQueueDrain verifies that queued requests are assigned
// to a provider when it becomes idle.
func TestIntegration_RequestQueueDrain(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	srv.SetChallengeInterval(200 * time.Millisecond)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKey := testkit.PublicKeyB64()
	model := "queue-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	conn := testkit.ConnectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Set trust level and mark challenge as verified.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	providerID := reg.ProviderIDs()[0]
	p := reg.GetProvider(providerID)

	// Fill the provider to max concurrency with dummy pending requests.
	for i := range registry.DefaultMaxConcurrent {
		pr := &registry.PendingRequest{
			RequestID:  "dummy-" + string(rune('a'+i)),
			ProviderID: providerID,
			Model:      model,
			ChunkCh:    make(chan registry.ProviderChunk, 1),
			CompleteCh: make(chan protocol.UsageInfo, 1),
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		}
		p.AddPending(pr)
	}

	// Verify provider is at max concurrency and not available.
	if found := testkit.FindRoutableProvider(reg, model); found != nil {
		t.Fatal("provider at max concurrency should not be routable")
	}

	// Enqueue a request into the queue.
	queuedReq := &registry.QueuedRequest{
		RequestID:  "queued-req-1",
		Model:      model,
		ResponseCh: make(chan *registry.Provider, 1),
	}
	if err := reg.Queue().Enqueue(queuedReq); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	if reg.Queue().QueueSize(model) != 1 {
		t.Fatalf("queue size = %d, want 1", reg.Queue().QueueSize(model))
	}

	// Simulate one request completing: remove a pending request.
	p.RemovePending("dummy-a")

	// Call SetProviderIdle which should drain the queue.
	reg.SetProviderIdle(providerID)

	// The queued request should receive a provider within a short time.
	select {
	case assigned := <-queuedReq.ResponseCh:
		if assigned == nil {
			t.Fatal("queued request received nil provider")
		}
		if assigned.ID != providerID {
			t.Errorf("assigned provider = %q, want %q", assigned.ID, providerID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("queued request was not assigned a provider")
	}

	// Queue should now be empty.
	if reg.Queue().QueueSize(model) != 0 {
		t.Errorf("queue size after drain = %d, want 0", reg.Queue().QueueSize(model))
	}
}
