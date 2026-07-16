package api

import (
	"context"
	"encoding/json"
	"errors"
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

func TestEndpointProviderBodiesAreLoweredBeforeSealing(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	publicKey := testPublicKeyB64()
	value, ok := testProviderKeys.Load(publicKey)
	if !ok {
		t.Fatalf("missing cached provider keypair for %q", publicKey)
	}
	keypair := value.(testProviderKeyPair)
	const model = "endpoint-lowering-model"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model}}, publicKey)
	defer conn.Close(websocket.StatusNormalClosure, "")
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	type providerResult struct {
		body []byte
		err  error
	}
	results := make(chan providerResult, 1)
	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				results <- providerResult{err: err}
				return
			}
			var envelope struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal(data, &envelope); err != nil {
				results <- providerResult{err: err}
				return
			}
			if envelope.Type == protocol.TypeAttestationChallenge {
				if err := conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, publicKey)); err != nil {
					results <- providerResult{err: err}
					return
				}
				continue
			}
			if envelope.Type != protocol.TypeInferenceRequest {
				continue
			}

			var request protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &request); err != nil {
				results <- providerResult{err: err}
				return
			}
			if request.EncryptedBody == nil {
				results <- providerResult{err: errMissingEncryptedProviderBody}
				return
			}
			payload := &e2e.EncryptedPayload{
				EphemeralPublicKey: request.EncryptedBody.EphemeralPublicKey,
				Ciphertext:         request.EncryptedBody.Ciphertext,
			}
			decrypted, err := e2e.DecryptWithPrivateKey(payload, keypair.private)
			results <- providerResult{body: decrypted, err: err}
			if err != nil {
				return
			}

			writeEncryptedTestChunk(t, ctx, conn, request, publicKey,
				`data: {"id":"chatcmpl-endpoint","choices":[{"delta":{"content":"ok"}}]}`+"\n\n")
			complete, _ := json.Marshal(protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: request.RequestID,
				Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
			})
			if err := conn.Write(ctx, websocket.MessageText, complete); err != nil {
				return
			}
		}
	}()

	tests := []struct {
		name         string
		path         string
		requestBody  string
		wantMessages []protocol.ChatMessage
		absent       []string
	}{
		{
			name:        "completions",
			path:        "/v1/completions",
			requestBody: `{"model":"endpoint-lowering-model","prompt":"Completion endpoint","max_tokens":32,"stream":true}`,
			wantMessages: []protocol.ChatMessage{
				{Role: "user", Content: "Completion endpoint"},
			},
			absent: []string{"prompt", "endpoint"},
		},
		{
			name:        "responses",
			path:        "/v1/responses",
			requestBody: `{"model":"endpoint-lowering-model","input":"Responses endpoint","max_output_tokens":32,"stream":true}`,
			wantMessages: []protocol.ChatMessage{
				{Role: "user", Content: "Responses endpoint"},
			},
			absent: []string{"input", "endpoint", "max_output_tokens"},
		},
		{
			name:        "messages",
			path:        "/v1/messages",
			requestBody: `{"model":"endpoint-lowering-model","system":"Be concise.","messages":[{"role":"user","content":"Messages endpoint"}],"max_tokens":32,"stream":true}`,
			wantMessages: []protocol.ChatMessage{
				{Role: "system", Content: "Be concise."},
				{Role: "user", Content: "Messages endpoint"},
			},
			absent: []string{"system", "endpoint"},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request, err := http.NewRequestWithContext(
				ctx, http.MethodPost, ts.URL+test.path, strings.NewReader(test.requestBody))
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Authorization", "Bearer test-key")
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			_, readErr := io.ReadAll(response.Body)
			response.Body.Close()
			if readErr != nil {
				t.Fatal(readErr)
			}
			if response.StatusCode != http.StatusOK {
				t.Fatalf("status = %d, want 200", response.StatusCode)
			}

			var result providerResult
			select {
			case result = <-results:
			case <-time.After(5 * time.Second):
				t.Fatal("timed out waiting for sealed provider body")
			}
			if result.err != nil {
				t.Fatalf("decrypt provider body: %v", result.err)
			}
			var body protocol.InferenceRequestBody
			if err := json.Unmarshal(result.body, &body); err != nil {
				t.Fatalf("provider body is not an OpenAI chat request: %v\n%s", err, result.body)
			}
			if len(body.Messages) != len(test.wantMessages) {
				t.Fatalf("messages = %#v, want %#v", body.Messages, test.wantMessages)
			}
			for index, want := range test.wantMessages {
				if body.Messages[index].Role != want.Role || body.Messages[index].Content != want.Content {
					t.Fatalf("message %d = %#v, want %#v", index, body.Messages[index], want)
				}
			}
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(result.body, &fields); err != nil {
				t.Fatal(err)
			}
			for _, key := range test.absent {
				if _, exists := fields[key]; exists {
					t.Errorf("provider body retained endpoint-native field %q: %s", key, result.body)
				}
			}
		})
	}
}

var errMissingEncryptedProviderBody = errors.New("inference request omitted encrypted provider body")
