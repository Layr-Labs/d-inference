package api

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

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// TestStreamingE2E sets up a full end-to-end streaming test with a simulated
// provider connected via WebSocket.
func TestStreamingE2E(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	// Start an httptest server.
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// Connect a fake provider via WebSocket.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	fixture := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "test-model", SizeBytes: 1000, ModelType: "test", Quantization: "4bit"}},
		pubKey)
	defer fixture.Close(websocket.StatusNormalClosure, "")
	conn := fixture.Conn
	reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
	reg.RecordChallengeSuccess(fixture.providerID)

	// Start a goroutine to handle inference on the provider side.
	// The provider must handle the immediate attestation challenge that
	// fires on registration before the inference request arrives.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Errorf("provider read: %v", err)
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
				if msgType == protocol.TypeRuntimeStatus || msgType == protocol.TypeTrustStatus {
					continue
				}
			}
			if err := json.Unmarshal(data, &inferReq); err != nil {
				t.Errorf("unmarshal inference request: %v", err)
				return
			}
			break
		}

		// Send two chunks.
		for _, word := range []string{"Hello", " world"} {
			writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
				`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"`+word+`"}}]}`+"\n\n")
		}

		// Send complete.
		complete := protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: inferReq.RequestID,
			Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5},
		}
		completeData, _ := json.Marshal(complete)
		if err := conn.Write(ctx, websocket.MessageText, completeData); err != nil {
			t.Errorf("write complete: %v", err)
			return
		}
	}()

	// Send a streaming chat completion request as a consumer.
	chatBody := `{"model":"test-model","messages":[{"role":"user","content":"hi"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}

	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("content-type = %q, want text/event-stream", ct)
	}

	// Read the full SSE response.
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}

	responseStr := string(body)
	if !strings.Contains(responseStr, "Hello") {
		t.Errorf("response should contain 'Hello', got: %s", responseStr)
	}
	if !strings.Contains(responseStr, "world") {
		t.Errorf("response should contain 'world', got: %s", responseStr)
	}
	if !strings.Contains(responseStr, "[DONE]") {
		t.Errorf("response should end with [DONE], got: %s", responseStr)
	}

	<-providerDone

	// Verify usage was recorded.
	records := st.UsageRecords()
	if len(records) != 1 {
		t.Fatalf("usage records = %d, want 1", len(records))
	}
	if records[0].PromptTokens != 10 {
		t.Errorf("prompt_tokens = %d, want 10", records[0].PromptTokens)
	}
	if records[0].CompletionTokens != 5 {
		t.Errorf("completion_tokens = %d, want 5", records[0].CompletionTokens)
	}
}

// TestNonStreamingE2E tests a non-streaming completion request.
func TestNonStreamingE2E(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	fixture := newTestProviderWS(t, ctx, ts.URL, reg,
		[]protocol.ModelInfo{{ID: "test-model", ModelType: "test", Quantization: "4bit"}},
		pubKey)
	defer fixture.Close(websocket.StatusNormalClosure, "")
	conn := fixture.Conn
	reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
	reg.RecordChallengeSuccess(fixture.providerID)

	// Provider goroutine — handles immediate challenge, then inference.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		var inferReq protocol.InferenceRequestMessage
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Errorf("provider read: %v", err)
				return
			}
			var raw map[string]interface{}
			if err := json.Unmarshal(data, &raw); err == nil {
				if raw["type"] == protocol.TypeAttestationChallenge {
					respData := makeValidChallengeResponse(data, pubKey)
					conn.Write(ctx, websocket.MessageText, respData)
					continue
				}
			}
			json.Unmarshal(data, &inferReq)
			break
		}

		// Send one chunk with the full content.
		writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
			`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello world"}}]}`+"\n\n")

		// Complete.
		complete := protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: inferReq.RequestID,
			Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 2},
		}
		completeData, _ := json.Marshal(complete)
		conn.Write(ctx, websocket.MessageText, completeData)
	}()

	// Non-streaming request.
	chatBody := `{"model":"test-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}

	var result map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	choices, ok := result["choices"].([]any)
	if !ok || len(choices) == 0 {
		t.Fatalf("no choices in response: %v", result)
	}
	choice := choices[0].(map[string]any)
	message := choice["message"].(map[string]any)
	content := message["content"].(string)

	if content != "Hello world" {
		t.Errorf("content = %q, want %q", content, "Hello world")
	}

	<-providerDone
}

func TestChatCompletionsRetriesAcceptedProviderErrorBeforeFirstChunk(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	connectProvider := func(pubKey string) *providerWSFixture {
		t.Helper()
		fixture := newTestProviderWS(t, ctx, ts.URL, reg,
			[]protocol.ModelInfo{{ID: "retry-model", ModelType: "test", Quantization: "4bit"}},
			pubKey)
		reg.SetTrustLevel(fixture.providerID, registry.TrustHardware)
		reg.RecordChallengeSuccess(fixture.providerID)
		return fixture
	}

	pubKey1 := testPublicKeyB64()
	provider1 := connectProvider(pubKey1)
	defer provider1.Close(websocket.StatusNormalClosure, "")
	conn1 := provider1.Conn

	firstGotRequest := make(chan protocol.InferenceRequestMessage, 1)
	secondReady := make(chan struct{})
	firstDone := make(chan struct{})
	go func() {
		defer close(firstDone)
		for {
			_, data, err := conn1.Read(ctx)
			if err != nil {
				t.Errorf("first provider read: %v", err)
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err == nil && raw["type"] == protocol.TypeAttestationChallenge {
				conn1.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey1))
				continue
			}
			var inferReq protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &inferReq); err != nil {
				t.Errorf("first provider unmarshal inference: %v", err)
				return
			}
			firstGotRequest <- inferReq
			<-secondReady
			accepted := protocol.InferenceAcceptedMessage{
				Type:      protocol.TypeInferenceAccepted,
				RequestID: inferReq.RequestID,
			}
			acceptedData, _ := json.Marshal(accepted)
			if err := conn1.Write(ctx, websocket.MessageText, acceptedData); err != nil {
				t.Errorf("first provider write accepted: %v", err)
				return
			}
			errMsg := protocol.InferenceErrorMessage{
				Type:       protocol.TypeInferenceError,
				RequestID:  inferReq.RequestID,
				Error:      "in-process model load failed",
				StatusCode: http.StatusServiceUnavailable,
			}
			errData, _ := json.Marshal(errMsg)
			if err := conn1.Write(ctx, websocket.MessageText, errData); err != nil {
				t.Errorf("first provider write error: %v", err)
			}
			return
		}
	}()

	respCh := make(chan struct {
		status int
		body   []byte
		err    error
	}, 1)
	go func() {
		chatBody := `{"model":"retry-model","messages":[{"role":"user","content":"hi"}],"stream":false}`
		httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
		httpReq.Header.Set("Authorization", "Bearer test-key")
		resp, err := http.DefaultClient.Do(httpReq)
		if err != nil {
			respCh <- struct {
				status int
				body   []byte
				err    error
			}{err: err}
			return
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		respCh <- struct {
			status int
			body   []byte
			err    error
		}{status: resp.StatusCode, body: body}
	}()

	<-firstGotRequest

	pubKey2 := testPublicKeyB64()
	provider2 := connectProvider(pubKey2)
	defer provider2.Close(websocket.StatusNormalClosure, "")
	conn2 := provider2.Conn

	secondDone := make(chan struct{})
	go func() {
		defer close(secondDone)
		for {
			_, data, err := conn2.Read(ctx)
			if err != nil {
				t.Errorf("second provider read: %v", err)
				return
			}
			var raw map[string]any
			if err := json.Unmarshal(data, &raw); err == nil && raw["type"] == protocol.TypeAttestationChallenge {
				conn2.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey2))
				continue
			}
			var inferReq protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &inferReq); err != nil {
				t.Errorf("second provider unmarshal inference: %v", err)
				return
			}
			writeEncryptedTestChunk(t, ctx, conn2, inferReq, pubKey2,
				`data: {"id":"chatcmpl-2","choices":[{"delta":{"content":"retry ok"}}]}`+"\n\n")
			complete := protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: inferReq.RequestID,
				Usage:     protocol.UsageInfo{PromptTokens: 4, CompletionTokens: 2},
			}
			completeData, _ := json.Marshal(complete)
			if err := conn2.Write(ctx, websocket.MessageText, completeData); err != nil {
				t.Errorf("second provider write complete: %v", err)
			}
			return
		}
	}()
	close(secondReady)

	got := <-respCh
	if got.err != nil {
		t.Fatalf("http request: %v", got.err)
	}
	if got.status != http.StatusOK {
		t.Fatalf("status = %d, body = %s", got.status, got.body)
	}
	if !strings.Contains(string(got.body), "retry ok") {
		t.Fatalf("response did not come from retry provider: %s", got.body)
	}
	<-firstDone
	<-secondDone
}
