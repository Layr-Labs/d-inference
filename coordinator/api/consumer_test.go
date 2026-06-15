package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"golang.org/x/crypto/nacl/box"
	"nhooyr.io/websocket"
)

func testServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	return srv, st
}

func TestHealthEndpoint(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", w.Code, http.StatusOK)
	}

	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("status = %v, want ok", body["status"])
	}
}

func TestHealthNoAuthRequired(t *testing.T) {
	srv, _ := testServer(t)

	// No Authorization header.
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("health should not require auth, got status %d", w.Code)
	}
}

func TestChatCompletionsNoAuth(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestChatCompletionsInvalidKey(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestChatCompletionsInvalidJSON(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{bad"))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestChatCompletionsMissingModel(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestChatCompletionsMissingMessages(t *testing.T) {
	srv, _ := testServer(t)

	body := `{"model":"test"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want %d", w.Code, http.StatusBadRequest)
	}
}

func TestChatCompletionsNoProvider(t *testing.T) {
	srv, _ := testServer(t)

	// Set a catalog so the unknown model returns 404 immediately instead of
	// blocking for the full 120s queue timeout.
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "known-model"}})

	body := `{"model":"nonexistent-model","messages":[{"role":"user","content":"hi"}]}`
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want %d", w.Code, http.StatusNotFound)
	}
}

func TestListModelsWithAuth(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", w.Code, http.StatusOK)
	}

	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body["object"] != "list" {
		t.Errorf("object = %v, want list", body["object"])
	}
}

func TestListModelsNoAuth(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d", w.Code, http.StatusUnauthorized)
	}
}

func TestCORSHeaders(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	origin := w.Header().Get("Access-Control-Allow-Origin")
	if origin == "*" {
		t.Errorf("CORS origin must not be wildcard, got %q", origin)
	}
	if origin == "" {
		t.Errorf("CORS origin header missing")
	}
}

func TestCORSPreflight(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodOptions, "/v1/chat/completions", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNoContent {
		t.Errorf("status = %d, want %d", w.Code, http.StatusNoContent)
	}
}

// TestCORSPublicEndpointsAllowAnyOrigin verifies the public, non-credentialed
// read endpoints (consumed by the marketing site) are readable cross-origin via
// a wildcard, while credentialed endpoints stay locked to a single origin.
func TestCORSPublicEndpointsAllowAnyOrigin(t *testing.T) {
	srv, _ := testServer(t)

	for _, path := range []string{"/v1/models/catalog", "/v1/pricing"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != "*" {
			t.Errorf("%s: Access-Control-Allow-Origin = %q, want \"*\"", path, got)
		}
		// A wildcard origin must never be paired with credentials.
		if got := w.Header().Get("Access-Control-Allow-Credentials"); got != "" {
			t.Errorf("%s: Access-Control-Allow-Credentials = %q, want empty", path, got)
		}
	}

	// A non-public endpoint keeps the locked single origin (never wildcard).
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if got := w.Header().Get("Access-Control-Allow-Origin"); got == "*" || got == "" {
		t.Errorf("/health: Access-Control-Allow-Origin = %q, want a specific origin", got)
	}

	// /v1/pricing also serves authenticated PUT/DELETE. A preflight for a
	// non-GET method must keep the credentialed, single-origin CORS (not the
	// wildcard public GET headers) so the mutation's preflight is accepted.
	preflight := httptest.NewRequest(http.MethodOptions, "/v1/pricing", nil)
	preflight.Header.Set("Access-Control-Request-Method", http.MethodDelete)
	pw := httptest.NewRecorder()
	srv.Handler().ServeHTTP(pw, preflight)
	if got := pw.Header().Get("Access-Control-Allow-Origin"); got == "*" || got == "" {
		t.Errorf("DELETE /v1/pricing preflight: Allow-Origin = %q, want the configured origin (not wildcard)", got)
	}
	if got := pw.Header().Get("Access-Control-Allow-Credentials"); got != "true" {
		t.Errorf("DELETE /v1/pricing preflight: Allow-Credentials = %q, want \"true\"", got)
	}
	if got := pw.Header().Get("Access-Control-Allow-Methods"); got != "GET, POST, PUT, DELETE, OPTIONS" {
		t.Errorf("DELETE /v1/pricing preflight: Allow-Methods = %q, want the credentialed method set", got)
	}
}

type testProviderKeyPair struct {
	public  [32]byte
	private [32]byte
}

var testProviderKeys sync.Map

func testPrivacyCaps() *protocol.PrivacyCapabilities {
	return &protocol.PrivacyCapabilities{
		TextBackendInprocess:    true,
		TextProxyDisabled:       true,
		PythonRuntimeLocked:     true,
		DangerousModulesBlocked: true,
		SIPEnabled:              true,
		AntiDebugEnabled:        true,
		CoreDumpsDisabled:       true,
		EnvScrubbed:             true,
	}
}

// testPublicKeyB64 generates a real X25519 keypair for tests and returns the
// provider public key. The matching private key is cached so test providers can
// encrypt response chunks back to the coordinator.
func testPublicKeyB64() string {
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	key := base64.StdEncoding.EncodeToString(pub[:])
	testProviderKeys.Store(key, testProviderKeyPair{
		public:  *pub,
		private: *priv,
	})
	return key
}

func testEncryptedChunk(t *testing.T, inferReq protocol.InferenceRequestMessage, providerPublicKey, sseData string) protocol.InferenceResponseChunkMessage {
	t.Helper()
	if inferReq.EncryptedBody == nil {
		t.Fatal("inference request missing encrypted body")
	}

	value, ok := testProviderKeys.Load(providerPublicKey)
	if !ok {
		t.Fatalf("missing provider keypair for %q", providerPublicKey)
	}
	keypair := value.(testProviderKeyPair)
	coordinatorPub, err := e2e.ParsePublicKey(inferReq.EncryptedBody.EphemeralPublicKey)
	if err != nil {
		t.Fatalf("parse coordinator public key: %v", err)
	}
	payload, err := e2e.Encrypt([]byte(sseData), coordinatorPub, &e2e.SessionKeys{
		PublicKey:  keypair.public,
		PrivateKey: keypair.private,
	})
	if err != nil {
		t.Fatalf("encrypt test chunk: %v", err)
	}

	return protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: inferReq.RequestID,
		EncryptedData: &protocol.EncryptedPayload{
			EphemeralPublicKey: payload.EphemeralPublicKey,
			Ciphertext:         payload.Ciphertext,
		},
	}
}

func writeEncryptedTestChunk(t *testing.T, ctx context.Context, conn *websocket.Conn, inferReq protocol.InferenceRequestMessage, providerPublicKey, sseData string) {
	t.Helper()
	chunk := testEncryptedChunk(t, inferReq, providerPublicKey, sseData)
	data, _ := json.Marshal(chunk)
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("write encrypted chunk: %v", err)
	}
}

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

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	// Send register message (with public key — encryption is mandatory).
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models: []protocol.ModelInfo{
			{ID: "test-model", SizeBytes: 1000, ModelType: "test", Quantization: "4bit"},
		},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Give the server a moment to process registration.
	time.Sleep(100 * time.Millisecond)

	// Upgrade provider to hardware trust and mark challenge as verified
	// so it's eligible for routing (FindProviderWithTrust requires a
	// recent LastChallengeVerified).
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

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

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	// Register (with public key — encryption is mandatory).
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "test-model", ModelType: "test", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	conn.Write(ctx, websocket.MessageText, regData)
	time.Sleep(100 * time.Millisecond)

	// Upgrade provider to hardware trust and mark challenge as verified
	// so it's eligible for routing (FindProviderWithTrust requires a
	// recent LastChallengeVerified).
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

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

	trustAllProviders := func() {
		for _, id := range reg.ProviderIDs() {
			reg.SetTrustLevel(id, registry.TrustHardware)
			reg.RecordChallengeSuccess(id)
		}
	}
	connectProvider := func(pubKey string) *websocket.Conn {
		t.Helper()
		wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
		conn, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("websocket dial: %v", err)
		}
		regMsg := protocol.RegisterMessage{
			Type:                    protocol.TypeRegister,
			Hardware:                protocol.Hardware{ChipName: "M3 Max", MemoryGB: 64},
			Models:                  []protocol.ModelInfo{{ID: "retry-model", ModelType: "test", Quantization: "4bit"}},
			Backend:                 "mlx-swift",
			PublicKey:               pubKey,
			EncryptedResponseChunks: true,
			PrivacyCapabilities:     testPrivacyCaps(),
		}
		regData, _ := json.Marshal(regMsg)
		if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
			t.Fatalf("write register: %v", err)
		}
		time.Sleep(100 * time.Millisecond)
		trustAllProviders()
		return conn
	}

	pubKey1 := testPublicKeyB64()
	conn1 := connectProvider(pubKey1)
	defer conn1.Close(websocket.StatusNormalClosure, "")

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
			time.Sleep(50 * time.Millisecond)
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
	conn2 := connectProvider(pubKey2)
	defer conn2.Close(websocket.StatusNormalClosure, "")

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

func TestExtractMessage(t *testing.T) {
	chunks := []string{
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n",
	}

	msg := extractMessage(chunks)
	if msg.Content != "Hello world" {
		t.Errorf("content = %q, want %q", msg.Content, "Hello world")
	}
	if len(msg.ToolCalls) != 0 {
		t.Errorf("tool_calls = %v, want empty", msg.ToolCalls)
	}
}

func TestExtractMessageEmpty(t *testing.T) {
	msg := extractMessage(nil)
	if msg.Content != "" {
		t.Errorf("content = %q, want empty", msg.Content)
	}
}

func TestExtractMessageWithToolCalls(t *testing.T) {
	chunks := []string{
		`data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"lo"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"cation\":"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"SF\"}"}}]}}]}`,
	}

	msg := extractMessage(chunks)
	if msg.Content != "" {
		t.Errorf("content = %q, want empty", msg.Content)
	}
	if len(msg.ToolCalls) != 1 {
		t.Fatalf("tool_calls length = %d, want 1", len(msg.ToolCalls))
	}
	tc := msg.ToolCalls[0]
	if tc["id"] != "call_abc" {
		t.Errorf("tool_call id = %v, want call_abc", tc["id"])
	}
	fn := tc["function"].(map[string]any)
	if fn["name"] != "get_weather" {
		t.Errorf("function name = %v, want get_weather", fn["name"])
	}
	if fn["arguments"] != `{"location":"SF"}` {
		t.Errorf("function arguments = %v, want {\"location\":\"SF\"}", fn["arguments"])
	}
}

func TestNormalizeSSEChunk(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		wantChecks func(t *testing.T, got string)
	}{
		{
			name:  "null content becomes empty string",
			input: `data: {"choices":[{"delta":{"content":null}}]}`,
			wantChecks: func(t *testing.T, got string) {
				if !strings.Contains(got, `"content":""`) {
					t.Errorf("expected content to be empty string, got: %s", got)
				}
			},
		},
		{
			name:  "null tool_calls becomes empty array",
			input: `data: {"choices":[{"delta":{"content":"hi","tool_calls":null}}]}`,
			wantChecks: func(t *testing.T, got string) {
				if !strings.Contains(got, `"tool_calls":[]`) {
					t.Errorf("expected tool_calls to be empty array, got: %s", got)
				}
			},
		},
		{
			name:  "usage null is removed entirely",
			input: `data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":null,"reasoning":null,"tool_calls":null,"reasoning_content":null},"finish_reason":null}],"usage":null}`,
			wantChecks: func(t *testing.T, got string) {
				if strings.Contains(got, `"usage"`) {
					t.Errorf("expected usage to be removed, got: %s", got)
				}
				if !strings.Contains(got, `"content":""`) {
					t.Errorf("expected content to be empty string, got: %s", got)
				}
				if !strings.Contains(got, `"reasoning":""`) {
					t.Errorf("expected reasoning to be empty string, got: %s", got)
				}
				if !strings.Contains(got, `"tool_calls":[]`) {
					t.Errorf("expected tool_calls to be empty array, got: %s", got)
				}
				// Both reasoning and reasoning_content should be present:
				// reasoning_content for AI SDK compatibility, reasoning
				// for ForgeCode and other clients.
				if !strings.Contains(got, `"reasoning_content"`) {
					t.Errorf("expected reasoning_content to be preserved for AI SDK, got: %s", got)
				}
			},
		},
		{
			name:  "no nulls returns unchanged",
			input: `data: {"choices":[{"delta":{"content":"hello"}}]}`,
			wantChecks: func(t *testing.T, got string) {
				if got != `data: {"choices":[{"delta":{"content":"hello"}}]}` {
					t.Errorf("expected unchanged, got: %s", got)
				}
			},
		},
		{
			name:  "valid usage object is preserved",
			input: `data: {"id":"1","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}`,
			wantChecks: func(t *testing.T, got string) {
				if !strings.Contains(got, `"prompt_tokens"`) {
					t.Errorf("expected usage to be preserved, got: %s", got)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeSSEChunk(tt.input)
			tt.wantChecks(t, got)
		})
	}
}

func TestNormalizeCompleteChatResponse(t *testing.T) {
	resp := map[string]any{
		"id":     "chatcmpl-1",
		"object": "chat.completion",
		"model":  "/Users/provider/.cache/huggingface/hub/models--mlx-community--MiniMax-M2.5-8bit/snapshots/main",
		"choices": []any{
			map[string]any{
				"index": 0,
				"message": map[string]any{
					"role":              "assistant",
					"content":           "<think>work through it</think>\n\n4",
					"reasoning_content": "existing reasoning",
					"tool_calls":        nil,
				},
			},
		},
		"system_fingerprint": nil,
	}

	normalizeCompleteChatResponse(resp, "mlx-community/MiniMax-M2.5-8bit")

	if resp["model"] != "mlx-community/MiniMax-M2.5-8bit" {
		t.Fatalf("model = %v", resp["model"])
	}
	if _, ok := resp["system_fingerprint"]; ok {
		t.Fatalf("system_fingerprint should be removed: %#v", resp)
	}
	message := resp["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if message["content"] != "4" {
		t.Fatalf("content = %q, want 4", message["content"])
	}
	if _, ok := message["reasoning_content"]; ok {
		t.Fatalf("reasoning_content should be removed: %#v", message)
	}
	if _, ok := message["tool_calls"]; ok {
		t.Fatalf("null tool_calls should be removed: %#v", message)
	}
	reasoning := message["reasoning"].(string)
	if !strings.Contains(reasoning, "existing reasoning") || !strings.Contains(reasoning, "work through it") {
		t.Fatalf("reasoning was not merged correctly: %q", reasoning)
	}
}

func TestNormalizeCompleteChatResponseNullContent(t *testing.T) {
	resp := map[string]any{
		"object": "chat.completion",
		"choices": []any{
			map[string]any{
				"message": map[string]any{
					"role":    "assistant",
					"content": nil,
				},
			},
		},
	}

	normalizeCompleteChatResponse(resp, "test-model")

	message := resp["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if message["content"] != "" {
		t.Fatalf("content = %v, want empty string", message["content"])
	}
}

func TestResponsesRequestToChatCompletions(t *testing.T) {
	req := map[string]any{
		"model":             "mlx-community/gemma-4-26b-a4b-it-8bit",
		"max_output_tokens": float64(64),
		"input": []any{
			map[string]any{
				"role": "user",
				"content": []any{
					map[string]any{"type": "input_text", "text": "Reply exactly OK"},
				},
			},
		},
		"tools": []any{
			map[string]any{
				"type":        "function",
				"name":        "get_current_weather",
				"description": "Get weather",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"city": map[string]any{"type": "string"},
					},
				},
			},
		},
		"tool_choice": map[string]any{"type": "function", "name": "get_current_weather"},
	}

	got, err := responsesRequestToChatCompletions(req)
	if err != nil {
		t.Fatalf("responsesRequestToChatCompletions: %v", err)
	}
	if _, ok := got["input"]; ok {
		t.Fatalf("input should not be forwarded to chat backend: %#v", got)
	}
	if got["max_tokens"] != 64 {
		t.Fatalf("max_tokens = %v, want 64", got["max_tokens"])
	}
	messages := got["messages"].([]map[string]any)
	if messages[0]["role"] != "user" || messages[0]["content"] != "Reply exactly OK" {
		t.Fatalf("messages = %#v", messages)
	}
	tools := got["tools"].([]any)
	firstTool := tools[0].(map[string]any)
	fn := firstTool["function"].(map[string]any)
	if firstTool["type"] != "function" || fn["name"] != "get_current_weather" {
		t.Fatalf("tools = %#v", tools)
	}
	choiceFn := got["tool_choice"].(map[string]any)["function"].(map[string]any)
	if choiceFn["name"] != "get_current_weather" {
		t.Fatalf("tool_choice = %#v", got["tool_choice"])
	}
}

func TestResponsesInputToolTranscriptToChatMessages(t *testing.T) {
	input := []any{
		map[string]any{
			"role":    "user",
			"content": []any{map[string]any{"type": "input_text", "text": "weather?"}},
		},
		map[string]any{
			"type":      "function_call",
			"call_id":   "call_123",
			"name":      "get_current_weather",
			"arguments": `{"city":"Paris"}`,
		},
		map[string]any{
			"type":    "function_call_output",
			"call_id": "call_123",
			"output":  `{"temperature":21}`,
		},
	}

	messages, err := responsesInputToChatMessages(input)
	if err != nil {
		t.Fatalf("responsesInputToChatMessages: %v", err)
	}
	if len(messages) != 3 {
		t.Fatalf("len(messages) = %d, want 3: %#v", len(messages), messages)
	}
	if messages[1]["role"] != "assistant" {
		t.Fatalf("second message = %#v", messages[1])
	}
	toolCalls := messages[1]["tool_calls"].([]map[string]any)
	if toolCalls[0]["id"] != "call_123" {
		t.Fatalf("tool_calls = %#v", toolCalls)
	}
	if messages[2]["role"] != "tool" || messages[2]["tool_call_id"] != "call_123" {
		t.Fatalf("third message = %#v", messages[2])
	}
}

func TestChatCompletionToResponses(t *testing.T) {
	chat := types.ChatCompletionResponse{
		ID:      "chatcmpl-test",
		Object:  "chat.completion",
		Created: 123,
		Model:   "local-path",
		Choices: []types.ChatCompletionChoice{{
			FinishReason: "tool_calls",
			Message: types.ChatCompletionMessage{
				Role:      "assistant",
				Content:   "",
				Reasoning: "need weather",
				ToolCalls: []map[string]any{
					{
						"id":   "call_123",
						"type": "function",
						"function": map[string]any{
							"name":      "get_current_weather",
							"arguments": `{"city":"Paris"}`,
						},
					},
				},
			},
		}},
		Usage: types.ChatCompletionUsage{
			PromptTokens:     10,
			CompletionTokens: 5,
			TotalTokens:      15,
		},
	}

	got := chatCompletionToResponses(chat, "mlx-community/gemma-4-26b-a4b-it-8bit", "", "")
	if got.Object != "response" || got.Model != "mlx-community/gemma-4-26b-a4b-it-8bit" {
		t.Fatalf("response metadata = %#v", got)
	}
	output := got.Output
	if output[0].(map[string]any)["type"] != "reasoning" {
		t.Fatalf("first output = %#v", output[0])
	}
	call := output[1].(map[string]any)
	if call["type"] != "function_call" || call["call_id"] != "call_123" {
		t.Fatalf("function call output = %#v", call)
	}
	usage := got.Usage
	if usage.InputTokens != 10 || usage.OutputTokens != 5 {
		t.Fatalf("usage = %#v", usage)
	}

	// Verify wire format preserves zero-valued fields.
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	wire := string(b)
	if !strings.Contains(wire, `"incomplete_details"`) {
		t.Errorf("wire output missing incomplete_details field: %s", wire)
	}
	if !strings.Contains(wire, `"cached_tokens"`) {
		t.Errorf("wire output missing cached_tokens in usage details: %s", wire)
	}
	if !strings.Contains(wire, `"reasoning_tokens"`) {
		t.Errorf("wire output missing reasoning_tokens in usage details: %s", wire)
	}
}

func TestExtractMessageWithNullFields(t *testing.T) {
	// Simulates real vllm-mlx chunks where the first chunk has null content
	// and subsequent chunks have actual content.
	chunks := []string{
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}]}`,
	}

	msg := extractMessage(chunks)
	if msg.Content != "Hello world" {
		t.Errorf("content = %q, want %q", msg.Content, "Hello world")
	}
}

func TestExtractMessageWithReasoningContentAndThinkTags(t *testing.T) {
	chunks := []string{
		`data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}`,
		`data: {"choices":[{"delta":{"content":"<think>more hidden</think>\n\n4"}}]}`,
	}

	msg := extractMessage(chunks)
	if msg.Content != "4" {
		t.Fatalf("content = %q, want 4", msg.Content)
	}
	if !strings.Contains(msg.Reasoning, "hidden") || !strings.Contains(msg.Reasoning, "more hidden") {
		t.Fatalf("reasoning not preserved: %q", msg.Reasoning)
	}
}

// TestProviderEarningsEndpoint verifies the /v1/provider/earnings endpoint
// returns balance and payout info for a provider wallet address.
func TestProviderEarningsEndpoint(t *testing.T) {
	srv, st := testServer(t)

	// Credit a provider wallet directly (simulates inference completion flow)
	providerWallet := "0xProviderWallet1234567890abcdef1234567890"
	_ = st.Credit(providerWallet, 450_000, store.LedgerPayout, "job-1") // $0.45
	_ = st.Credit(providerWallet, 900_000, store.LedgerPayout, "job-2") // $0.90

	// Query earnings — no auth required
	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet="+providerWallet, nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	// Balance should be 450,000 + 900,000 = 1,350,000 micro-USD
	balance := resp["balance_micro_usd"].(float64)
	if balance != 1_350_000 {
		t.Errorf("balance_micro_usd = %v, want 1350000", balance)
	}

	balanceUSD := resp["balance_usd"].(string)
	if balanceUSD != "1.350000" {
		t.Errorf("balance_usd = %v, want 1.350000", balanceUSD)
	}

	// Should have ledger entries
	ledger := resp["ledger"].([]any)
	if len(ledger) != 2 {
		t.Errorf("ledger entries = %d, want 2", len(ledger))
	}
}

func TestProviderEarningsUsesStoredPayoutRecords(t *testing.T) {
	srv, _ := testServer(t)

	wallet := "0xStoredPayoutWallet1234567890abcdef1234"
	if err := srv.store.CreditProviderWallet(&store.ProviderPayout{
		ProviderAddress: wallet,
		AmountMicroUSD:  250_000,
		Model:           "qwen3.5-9b",
		JobID:           "job-stored",
	}); err != nil {
		t.Fatalf("CreditProviderWallet: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet="+wallet, nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	payouts, ok := resp["payouts"].([]any)
	if !ok || len(payouts) != 1 {
		t.Fatalf("payouts = %#v, want single payout", resp["payouts"])
	}

	payout, ok := payouts[0].(map[string]any)
	if !ok {
		t.Fatalf("payout = %#v, want object", payouts[0])
	}
	if payout["model"] != "qwen3.5-9b" {
		t.Errorf("payout model = %v, want qwen3.5-9b", payout["model"])
	}
	if settled, _ := payout["settled"].(bool); settled {
		t.Errorf("payout settled = %v, want false", payout["settled"])
	}
}

// ---------------------------------------------------------------------------
// Benchmarks for normalizeSSEChunk (called per SSE chunk in streaming path)
// ---------------------------------------------------------------------------

func BenchmarkNormalizeSSEChunk_NoNulls(b *testing.B) {
	b.ReportAllocs()
	// Fast path: no null fields, function should return early.
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"content":"Hello world"},"finish_reason":null}]}`

	b.ResetTimer()
	for range b.N {
		_ = normalizeSSEChunk(chunk)
	}
}

func BenchmarkNormalizeSSEChunk_WithNulls(b *testing.B) {
	b.ReportAllocs()
	// Slow path: has null content, tool_calls, reasoning_content that need fixing.
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":null,"reasoning_content":null},"finish_reason":null}],"usage":null,"system_fingerprint":null}`

	b.ResetTimer()
	for range b.N {
		_ = normalizeSSEChunk(chunk)
	}
}

func BenchmarkNormalizeSSEChunk_Usage(b *testing.B) {
	b.ReportAllocs()
	// Final chunk with usage object (should be preserved, not removed).
	chunk := `data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1700000000,"model":"qwen3.5-27b","choices":[],"usage":{"prompt_tokens":150,"completion_tokens":83,"total_tokens":233}}`

	b.ResetTimer()
	for range b.N {
		_ = normalizeSSEChunk(chunk)
	}
}

func TestProviderEarningsNoWallet(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestProviderEarningsViaHeader(t *testing.T) {
	srv, st := testServer(t)

	wallet := "0xHeaderWallet0000000000000000000000000000"
	_ = st.Credit(wallet, 100_000, store.LedgerPayout, "job-h1")

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings", nil)
	req.Header.Set("X-Provider-Wallet", wallet)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["balance_micro_usd"].(float64) != 100_000 {
		t.Errorf("balance_micro_usd = %v, want 100000", resp["balance_micro_usd"])
	}
}

func TestProviderEarningsEmptyWallet(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet=0xNewWallet", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["balance_micro_usd"].(float64) != 0 {
		t.Errorf("balance_micro_usd = %v, want 0", resp["balance_micro_usd"])
	}
	if resp["total_jobs"].(float64) != 0 {
		t.Errorf("total_jobs = %v, want 0", resp["total_jobs"])
	}
}

// TestApproximateTokenCount verifies the len/4 routing heuristic.
func TestApproximateTokenCount(t *testing.T) {
	tests := []struct {
		name  string
		input any
		want  int
	}{
		{"nil", nil, 0},
		{"empty string", "", 0},
		{"single char", "a", 1},
		{"short ASCII", "hello", 1},                        // 5/4 = 1
		{"english prose", "The quick brown fox jumps.", 6}, // 26/4 = 6
		{"16 bytes", "0123456789abcdef", 4},                // 16/4 = 4
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := approximateTokenCount(tt.input)
			if got != tt.want {
				t.Errorf("approximateTokenCount(%v) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

// TestApproximateTokenCountUpperBound verifies that the billing upper bound
// returns len(text) — guaranteed >= actual BPE tokens for any tokenizer.
func TestApproximateTokenCountUpperBound(t *testing.T) {
	tests := []struct {
		name  string
		input any
		want  int
	}{
		{"nil", nil, 0},
		{"empty string", "", 0},
		{"single char", "a", 1},
		{"short ASCII", "hello", 5},
		{"english prose", "The quick brown fox jumps over the lazy dog.", 44},
		{"code snippet", "func main() { fmt.Println(\"hello\") }", 36},
		{"multibyte UTF-8", "こんにちは世界", 21}, // 7 chars × 3 bytes each
		{"emoji", "👋🌍", 8},                 // 2 emoji × 4 bytes each
		{"chat template tags", "<|im_start|>system\nYou are helpful.<|im_end|>", 45},
		{"json object", map[string]string{"role": "user", "content": "hi"}, len(`{"content":"hi","role":"user"}`)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := approximateTokenCountUpperBound(tt.input)
			if got != tt.want {
				t.Errorf("approximateTokenCountUpperBound(%v) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

// TestBillingEstimateAlwaysGERoutingEstimate confirms that the billing
// upper bound is always >= the routing heuristic for the same input.
func TestBillingEstimateAlwaysGERoutingEstimate(t *testing.T) {
	inputs := []string{
		"Hello, world!",
		"def fibonacci(n):\n    if n <= 1:\n        return n\n    return fibonacci(n-1) + fibonacci(n-2)",
		"SELECT u.id, u.name FROM users u WHERE u.active = true ORDER BY u.created_at DESC LIMIT 10;",
		"これはテストです。日本語のテキストはトークン数が多くなります。",
		strings.Repeat("a", 1000),
	}
	for _, input := range inputs {
		routing := approximateTokenCount(input)
		billing := approximateTokenCountUpperBound(input)
		if billing < routing {
			t.Errorf("billing(%d) < routing(%d) for %q", billing, routing, input[:min(20, len(input))])
		}
	}
}

// TestEstimatePromptTokens verifies the routing estimate for different
// request field layouts.
func TestEstimatePromptTokens(t *testing.T) {
	tests := []struct {
		name  string
		input map[string]any
	}{
		{
			name:  "messages field",
			input: map[string]any{"messages": []any{map[string]any{"role": "user", "content": "hello"}}},
		},
		{
			name:  "prompt field",
			input: map[string]any{"prompt": "Tell me a story"},
		},
		{
			name:  "input field",
			input: map[string]any{"input": "Translate this"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			routing := estimatePromptTokens(tt.input)
			billing := estimateBillingPromptTokens(tt.input)
			if routing < 1 {
				t.Errorf("estimatePromptTokens() = %d, want >= 1", routing)
			}
			if billing < routing {
				t.Errorf("billing(%d) < routing(%d)", billing, routing)
			}
		})
	}
}

// TestResolveReasoningTokens covers the precedence between the provider's
// tokenizer-accurate count and the legacy completion-tokens fallback.
func TestResolveReasoningTokens(t *testing.T) {
	cases := []struct {
		name      string
		usage     protocol.UsageInfo
		reasoning string
		want      uint64
	}{
		{
			name:      "accurate count preferred",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 42},
			reasoning: "thinking...",
			want:      42,
		},
		{
			name:      "fallback to completion tokens for legacy provider",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 0},
			reasoning: "thinking...",
			want:      100,
		},
		{
			name:      "no reasoning content yields zero",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 0},
			reasoning: "",
			want:      0,
		},
		{
			name:      "accurate count wins even without reasoning text",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 7},
			reasoning: "",
			want:      7,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolveReasoningTokens(tc.usage, tc.reasoning); got != tc.want {
				t.Errorf("resolveReasoningTokens = %d, want %d", got, tc.want)
			}
		})
	}
}

// TestBuildNonStreamingResponseReasoningDetails verifies the chat
// completion usage object carries completion_tokens_details.reasoning_tokens
// only when there is a reasoning count to report.
func TestBuildNonStreamingResponseReasoningDetails(t *testing.T) {
	msg := extractedMessage{Content: "4", Reasoning: "2+2"}
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20, ReasoningTokens: 8}

	resp := buildNonStreamingResponse("req-1", "gpt-oss-20b", msg, usage, 0, "", "")
	if resp.Usage.CompletionTokensDetails == nil {
		t.Fatalf("expected completion_tokens_details, got nil")
	}
	if resp.Usage.CompletionTokensDetails.ReasoningTokens != 8 {
		t.Errorf("reasoning_tokens = %d, want 8", resp.Usage.CompletionTokensDetails.ReasoningTokens)
	}

	// Wire format must include the nested detail.
	b, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(b), `"completion_tokens_details":{"reasoning_tokens":8}`) {
		t.Errorf("wire missing reasoning detail: %s", b)
	}

	// No reasoning content => no details object (omitempty).
	plain := buildNonStreamingResponse("req-2", "gpt-oss-20b",
		extractedMessage{Content: "hi"},
		protocol.UsageInfo{PromptTokens: 3, CompletionTokens: 1}, 0, "", "")
	if plain.Usage.CompletionTokensDetails != nil {
		t.Errorf("expected no details for non-reasoning response, got %#v", plain.Usage.CompletionTokensDetails)
	}
	pb, _ := json.Marshal(plain)
	if strings.Contains(string(pb), "completion_tokens_details") {
		t.Errorf("non-reasoning wire should omit details: %s", pb)
	}
}

// TestBuildResponsesResponseReasoningTokens verifies the Responses API
// uses the accurate count when the provider supplies it.
func TestBuildResponsesResponseReasoningTokens(t *testing.T) {
	msg := extractedMessage{Content: "4", Reasoning: "2+2"}
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20, ReasoningTokens: 8}

	resp := buildResponsesResponse("req-1", "gpt-oss-20b", msg, usage, 0, "", "")
	if resp.Usage.OutputTokensDetail.ReasoningTokens != 8 {
		t.Errorf("reasoning_tokens = %d, want 8 (accurate count, not %d completion)",
			resp.Usage.OutputTokensDetail.ReasoningTokens, usage.CompletionTokens)
	}
}

// TestInjectReasoningDetailIntoRawUsage covers the passthrough path: a
// provider-reported accurate reasoning count is spliced into the raw
// chat.completion usage object, without overriding an existing value.
func TestInjectReasoningDetailIntoRawUsage(t *testing.T) {
	// Adds detail when absent.
	obj := map[string]any{
		"object": "chat.completion",
		"usage": map[string]any{
			"prompt_tokens":     float64(10),
			"completion_tokens": float64(30),
		},
	}
	injectReasoningDetailIntoRawUsage(obj, protocol.UsageInfo{CompletionTokens: 30, ReasoningTokens: 12})
	details := obj["usage"].(map[string]any)["completion_tokens_details"].(map[string]any)
	if details["reasoning_tokens"] != 12 {
		t.Errorf("reasoning_tokens = %v, want 12", details["reasoning_tokens"])
	}

	// No-op when the provider reported no reasoning count.
	plain := map[string]any{"usage": map[string]any{"completion_tokens": float64(5)}}
	injectReasoningDetailIntoRawUsage(plain, protocol.UsageInfo{CompletionTokens: 5, ReasoningTokens: 0})
	if _, ok := plain["usage"].(map[string]any)["completion_tokens_details"]; ok {
		t.Errorf("expected no details injected for zero reasoning count")
	}

	// Never overrides an existing detail.
	existing := map[string]any{
		"usage": map[string]any{
			"completion_tokens_details": map[string]any{"reasoning_tokens": float64(99)},
		},
	}
	injectReasoningDetailIntoRawUsage(existing, protocol.UsageInfo{ReasoningTokens: 5})
	got := existing["usage"].(map[string]any)["completion_tokens_details"].(map[string]any)["reasoning_tokens"]
	if got != float64(99) {
		t.Errorf("reasoning_tokens = %v, want 99 (must not override)", got)
	}

	// No-op when there is no usage object at all.
	noUsage := map[string]any{"object": "chat.completion"}
	injectReasoningDetailIntoRawUsage(noUsage, protocol.UsageInfo{ReasoningTokens: 7})
	if _, ok := noUsage["usage"]; ok {
		t.Errorf("did not expect a usage object to be created")
	}
}

// TestDetectMediaRequirementAndTokenEstimate verifies media detection and that
// the media-aware estimator counts an image as a flat cost rather than its
// inflated base64 length (which would distort routing admission and billing).
func TestDetectMediaRequirementAndTokenEstimate(t *testing.T) {
	bigImage := "data:image/png;base64," + strings.Repeat("A", 200_000)
	parsed := map[string]any{
		"messages": []any{
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "text", "text": "what is in this image?"},
				map[string]any{"type": "image_url", "image_url": map[string]any{"url": bigImage}},
			}},
		},
	}
	if !detectMediaRequirement(parsed) {
		t.Fatal("expected media requirement detected for an image_url content part")
	}
	got := estimatePromptTokens(parsed)
	if got > 1000 {
		t.Fatalf("media-aware ROUTING estimate must ignore base64 length; got %d tokens for a 200KB image", got)
	}
	if got < imagePromptTokenCost {
		t.Fatalf("routing estimate should include the flat per-image cost (%d); got %d", imagePromptTokenCost, got)
	}
	// Billing intentionally stays a guaranteed UPPER bound (still counts the
	// base64 bytes) so it can never under-reserve; over-reservation is refunded
	// after inference. It must therefore exceed the small routing estimate here.
	if b := estimateBillingPromptTokens(parsed); b <= got {
		t.Fatalf("billing upper bound (%d) should exceed the routing estimate (%d) for a base64 image", b, got)
	}

	textParsed := map[string]any{
		"messages": []any{
			map[string]any{"role": "user", "content": "hello world"},
		},
	}
	if detectMediaRequirement(textParsed) {
		t.Fatal("a text-only request must not be flagged as requiring vision")
	}
}

// TestDetectMediaRequirementResponsesInput verifies the Responses API surface
// (input[].content parts) is gated too, so a media request there fails fast
// rather than being silently routed text-blind.
func TestDetectMediaRequirementResponsesInput(t *testing.T) {
	withImage := map[string]any{
		"input": []any{
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "input_text", "text": "describe"},
				map[string]any{"type": "input_image", "image_url": "data:image/png;base64,AAAA"},
			}},
		},
	}
	if !detectMediaRequirement(withImage) {
		t.Fatal("expected media detected in Responses API input parts")
	}
	textOnly := map[string]any{"input": "just a string prompt"}
	if detectMediaRequirement(textOnly) {
		t.Fatal("a string Responses input must not be flagged as media")
	}
}

// TestDetectMediaRequirementAnthropicImageBlock verifies Anthropic /v1/messages
// image content blocks ({"type":"image","source":...}) are detected for the
// vision routing gate, not just OpenAI-style image_url parts.
func TestDetectMediaRequirementAnthropicImageBlock(t *testing.T) {
	parsed := map[string]any{
		"messages": []any{
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "text", "text": "what is this?"},
				map[string]any{"type": "image", "source": map[string]any{
					"type": "base64", "media_type": "image/png", "data": "AAAA",
				}},
			}},
		},
	}
	if !detectMediaRequirement(parsed) {
		t.Fatal("expected Anthropic image content block to be detected as media")
	}
}

// TestBodyForProviderPenaltyGating verifies the coordinator strips the penalty
// fields that crash the pre-fix VLM path, but ONLY for vision requests routed to
// a provider below penaltySafeProviderVersion. Fixed providers and text requests
// keep their penalties. See bodyForProvider.
func TestBodyForProviderPenaltyGating(t *testing.T) {
	visionBody := []byte(`{"model":"gemma-4-26b","temperature":1.0,"repetition_penalty":1.0,` +
		`"presence_penalty":0.0,"frequency_penalty":0.0,"messages":[{"role":"user","content":[` +
		`{"type":"text","text":"what is this?"},` +
		`{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}`)
	textBody := []byte(`{"model":"gemma-4-26b","repetition_penalty":1.3,` +
		`"messages":[{"role":"user","content":"hello"}]}`)

	has := func(body []byte, key string) bool {
		var m map[string]any
		if err := json.Unmarshal(body, &m); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		_, ok := m[key]
		return ok
	}
	penalties := []string{"repetition_penalty", "presence_penalty", "frequency_penalty"}

	// Vision + pre-fix provider → penalties stripped, other fields kept.
	out := bodyForProvider(visionBody, true, &registry.Provider{Version: "0.6.6"})
	for _, k := range penalties {
		if has(out, k) {
			t.Fatalf("pre-fix vision provider: expected %q stripped", k)
		}
	}
	if !has(out, "temperature") || !has(out, "messages") {
		t.Fatal("pre-fix vision provider: non-penalty fields must be preserved")
	}

	// Vision + provider with unknown version → stripped (conservative).
	if has(bodyForProvider(visionBody, true, &registry.Provider{Version: ""}), "repetition_penalty") {
		t.Fatal("unknown-version vision provider: expected penalties stripped")
	}

	// Vision + fixed provider (== and > floor) → penalties preserved.
	for _, v := range []string{"0.6.7", "0.7.0"} {
		if !has(bodyForProvider(visionBody, true, &registry.Provider{Version: v}), "repetition_penalty") {
			t.Fatalf("fixed provider %s: penalties must pass through", v)
		}
	}

	// Text request (any provider) → penalties preserved.
	if !has(bodyForProvider(textBody, false, &registry.Provider{Version: "0.6.6"}), "repetition_penalty") {
		t.Fatal("text request: penalties must pass through")
	}

	// Vision + pre-fix provider but no penalty fields → returns rawBody unchanged.
	clean := []byte(`{"model":"gemma-4-26b","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}`)
	if out := bodyForProvider(clean, true, &registry.Provider{Version: "0.6.6"}); string(out) != string(clean) {
		t.Fatal("no-penalty vision body should be returned unchanged")
	}
}

// TestUsageChunkParseAndFinalize covers the parse-once + finalize helpers.
func TestUsageChunkParseAndFinalize(t *testing.T) {
	usageChunk := `data: {"object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`
	pr := &registry.PendingRequest{Model: "gpt-oss-20b"}

	obj, ok := parseUsageOnlyStreamChunk(usageChunk)
	if !ok {
		t.Fatal("expected the usage-only chunk to be detected + parsed")
	}
	out := finalizeUsageChunk(obj, protocol.UsageInfo{CompletionTokens: 50, ReasoningTokens: 8}, pr)
	if !strings.Contains(out, `"reasoning_tokens":8`) {
		t.Fatalf("expected reasoning_tokens spliced into usage; got %s", out)
	}

	// A content delta and a usage:null chunk are NOT usage-only chunks.
	if _, ok := parseUsageOnlyStreamChunk(`data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"x"}}]}`); ok {
		t.Fatal("a content delta must NOT be treated as a usage-only chunk")
	}
	if _, ok := parseUsageOnlyStreamChunk(`data: {"object":"chat.completion.chunk","choices":[],"usage":null}`); ok {
		t.Fatal("a usage:null chunk must NOT be treated as a usage-only chunk")
	}

	// No reasoning → no completion_tokens_details added.
	obj2, _ := parseUsageOnlyStreamChunk(usageChunk)
	if plain := finalizeUsageChunk(obj2, protocol.UsageInfo{CompletionTokens: 50}, pr); strings.Contains(plain, "completion_tokens_details") {
		t.Fatalf("expected no reasoning detail when ReasoningTokens=0; got %s", plain)
	}

	// Build id rewritten to the public alias.
	obj3, _ := parseUsageOnlyStreamChunk(usageChunk)
	prAlias := &registry.PendingRequest{Model: "gpt-oss-20b", PublicModel: "gpt-oss"}
	aliased := finalizeUsageChunk(obj3, protocol.UsageInfo{CompletionTokens: 50, ReasoningTokens: 8}, prAlias)
	if !strings.Contains(aliased, `"model":"gpt-oss"`) || strings.Contains(aliased, `"model":"gpt-oss-20b"`) {
		t.Fatalf("expected build id rewritten to the public alias; got %s", aliased)
	}
}

// TestStreamingChatReasoningTokensInUsage proves chat-completions STREAMING now
// reports the reasoning breakdown in the terminal usage chunk (the bug: reasoning
// was lumped into completion with no completion_tokens_details).
func TestStreamingChatReasoningTokensInUsage(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	pr := &registry.PendingRequest{
		RequestID:  "job-1",
		Model:      "gpt-oss-20b",
		ChunkCh:    make(chan string, 8),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
	}
	// Provider streams a content delta, then the include_usage chunk WITHOUT a
	// reasoning detail, then closes and reports the authoritative split via CompleteCh.
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 50, ReasoningTokens: 8}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, nil)

	body := rec.Body.String()
	if !strings.Contains(body, `"reasoning_tokens":8`) {
		t.Fatalf("streaming usage missing reasoning_tokens; body=\n%s", body)
	}
	if !strings.Contains(body, `"completion_tokens":50`) {
		t.Fatalf("completion_tokens should stay 50 (reasoning is a subset detail); body=\n%s", body)
	}
	if !strings.Contains(body, `"content":"hi"`) || !strings.Contains(body, "data: [DONE]") {
		t.Fatalf("expected the content delta and [DONE]; body=\n%s", body)
	}
	if strings.Count(body, `"usage":{`) != 1 {
		t.Fatalf("expected exactly one usage chunk (held + augmented, not doubled); body=\n%s", body)
	}
}

// TestStreamingChatUsageOnlyFirstChunk covers the zero-delta case: a completion
// that streams no content/reasoning deltas, so the include_usage frame is the very
// FIRST chunk handed to the handler. It must still be held and have the reasoning
// breakdown spliced in (not emitted raw), and must not be doubled.
func TestStreamingChatUsageOnlyFirstChunk(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	pr := &registry.PendingRequest{
		RequestID:  "job-1",
		Model:      "gpt-oss-20b",
		ChunkCh:    make(chan string, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
	}
	// No deltas at all — the stream closes immediately; the authoritative split
	// arrives on CompleteCh.
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 50, ReasoningTokens: 8}

	firstChunk := `data: {"id":"c1","object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, []string{firstChunk})

	body := rec.Body.String()
	if !strings.Contains(body, `"reasoning_tokens":8`) {
		t.Fatalf("usage-only first chunk must still get reasoning_tokens spliced; body=\n%s", body)
	}
	if !strings.Contains(body, `"completion_tokens":50`) {
		t.Fatalf("completion_tokens should stay 50; body=\n%s", body)
	}
	if strings.Count(body, `"usage":{`) != 1 {
		t.Fatalf("expected exactly one usage chunk (held + augmented, not raw + doubled); body=\n%s", body)
	}
	if !strings.Contains(body, "data: [DONE]") {
		t.Fatalf("expected [DONE] terminator; body=\n%s", body)
	}
}

// TestStreamingChatSingleDoneSignatureBeforeIt covers the SplittyDev report:
// the provider's own "data: [DONE]" was forwarded, then the coordinator
// appended a bare {"choices":[],se_signature,...} event and a SECOND [DONE].
// SDKs treat the first [DONE] as final and choke on the malformed trailer.
// Now: provider [DONE] swallowed, the signature rides a fully-shaped chunk,
// and exactly one [DONE] terminates the stream.
func TestStreamingChatSingleDoneSignatureBeforeIt(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	pr := &registry.PendingRequest{
		RequestID:    "job-1",
		Model:        "gpt-oss-20b",
		SESignature:  "sig-abc",
		ResponseHash: "hash-def",
		ChunkCh:      make(chan string, 8),
		ErrorCh:      make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:   make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"gpt-oss-20b","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"gpt-oss-20b","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}`
	pr.ChunkCh <- "data: [DONE]" // the provider's own terminator — must be swallowed
	close(pr.ChunkCh)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, nil)

	body := rec.Body.String()
	if got := strings.Count(body, "data: [DONE]"); got != 1 {
		t.Fatalf("expected exactly ONE [DONE]; got %d\nbody:\n%s", got, body)
	}
	if !strings.HasSuffix(strings.TrimSpace(body), "data: [DONE]") {
		t.Fatalf("[DONE] must be the FINAL event — nothing may trail it; body:\n%s", body)
	}
	sigIdx := strings.Index(body, `"se_signature":"sig-abc"`)
	doneIdx := strings.Index(body, "data: [DONE]")
	if sigIdx == -1 || sigIdx > doneIdx {
		t.Fatalf("signature event must precede the single [DONE]; body:\n%s", body)
	}
	// The signature event must be a fully-shaped chunk for strict decoders.
	var sigLine string
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, "se_signature") {
			sigLine = strings.TrimPrefix(line, "data: ")
			break
		}
	}
	var sigObj map[string]any
	if err := json.Unmarshal([]byte(sigLine), &sigObj); err != nil {
		t.Fatalf("signature event is not valid JSON: %v", err)
	}
	for _, k := range []string{"id", "object", "created", "model", "choices", "response_hash"} {
		if _, present := sigObj[k]; !present {
			t.Fatalf("signature event missing required field %q (breaks strict SDKs); got: %s", k, sigLine)
		}
	}
	if sigObj["object"] != "chat.completion.chunk" {
		t.Fatalf("signature event object must be chat.completion.chunk; got %v", sigObj["object"])
	}
}

// TestStreamingChatSignatureRidesUsageChunk: with stream_options.include_usage
// (a held usage-only chunk), the SE signature is spliced into that final
// well-formed chunk — no separate signature event, single [DONE].
func TestStreamingChatSignatureRidesUsageChunk(t *testing.T) {
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)

	pr := &registry.PendingRequest{
		RequestID:    "job-1",
		Model:        "gpt-oss-20b",
		SESignature:  "sig-abc",
		ResponseHash: "hash-def",
		ChunkCh:      make(chan string, 8),
		ErrorCh:      make(chan protocol.InferenceErrorMessage, 1),
		CompleteCh:   make(chan protocol.UsageInfo, 1),
	}
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"gpt-oss-20b","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}`
	pr.ChunkCh <- `data: {"id":"c1","object":"chat.completion.chunk","created":1,"model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`
	pr.ChunkCh <- "data: [DONE]"
	close(pr.ChunkCh)
	pr.CompleteCh <- protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 50, ReasoningTokens: 8}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rec := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(rec, req, pr, nil)

	body := rec.Body.String()
	if got := strings.Count(body, "data: [DONE]"); got != 1 {
		t.Fatalf("expected exactly ONE [DONE]; got %d\nbody:\n%s", got, body)
	}
	if got := strings.Count(body, "se_signature"); got != 1 {
		t.Fatalf("signature must appear exactly once (on the usage chunk); got %d\nbody:\n%s", got, body)
	}
	// One line carries usage + reasoning + signature together.
	var found bool
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, "se_signature") {
			found = strings.Contains(line, `"reasoning_tokens":8`) &&
				strings.Contains(line, `"usage"`) &&
				strings.Contains(line, `"response_hash":"hash-def"`)
		}
	}
	if !found {
		t.Fatalf("signature must ride the final usage chunk (with reasoning spliced); body:\n%s", body)
	}
	if !strings.HasSuffix(strings.TrimSpace(body), "data: [DONE]") {
		t.Fatalf("[DONE] must be the final event; body:\n%s", body)
	}
}

func TestWriteServiceUnavailableSetsRetryAfter(t *testing.T) {
	srv, _ := testServer(t)
	w := httptest.NewRecorder()
	srv.writeServiceUnavailable(w, "gpt-oss-20b")

	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}
	if ra := w.Header().Get("Retry-After"); ra == "" {
		t.Error("Retry-After header missing")
	} else if n, err := strconv.Atoi(ra); err != nil || n < 1 {
		t.Errorf("Retry-After = %q, want positive integer seconds", ra)
	}
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body.Error.Code != "service_unavailable" {
		t.Errorf("code = %q, want service_unavailable", body.Error.Code)
	}
}

func TestWriteTTFTTooSlowSets429RetryAfter(t *testing.T) {
	srv, _ := testServer(t)
	if got := srv.estimateTTFTRetryAfter("no-queue", 13*time.Second); got != 3 {
		t.Fatalf("Retry-After without queue = %d, want 3s over target", got)
	}

	model := "slow-ttft-model"
	for i := 0; i < 5; i++ {
		if err := srv.registry.Queue().Enqueue(&registry.QueuedRequest{RequestID: "queued-" + strconv.Itoa(i), Model: model}); err != nil {
			t.Fatal(err)
		}
	}

	w := httptest.NewRecorder()
	srv.writeTTFTTooSlow(w, model, model, 11*time.Second)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusTooManyRequests)
	}
	if got := w.Header().Get("Retry-After"); got != "15" {
		t.Fatalf("Retry-After = %q, want 15 from existing queue-depth estimate", got)
	}
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body.Error.Code != "rate_limit_exceeded" {
		t.Fatalf("code = %q, want rate_limit_exceeded", body.Error.Code)
	}
	if !strings.Contains(body.Error.Message, "10s TTFT target") {
		t.Fatalf("message = %q, want TTFT target detail", body.Error.Message)
	}
}

func TestTTFTAdmission429ForInferenceEndpoints(t *testing.T) {
	srv, _ := testServer(t)
	model := "route-slow-ttft-model"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})
	p := registerBuildsProvider(srv, "route-slow-provider", model)
	p.Mu().Lock()
	p.DecodeTPS = 100
	p.PrefillTPS = 400
	p.BackendCapacity.Slots[0].MaxTokensPotential = 2_000
	p.Mu().Unlock()

	cases := []struct {
		name string
		path string
		body string
	}{
		{
			name: "responses-style chat completions",
			path: "/v1/chat/completions",
			body: `{"model":"MODEL","input":"hello","max_output_tokens":128}`,
		},
		{
			name: "completions",
			path: "/v1/completions",
			body: `{"model":"MODEL","prompt":"hello","max_tokens":128}`,
		},
		{
			name: "anthropic messages",
			path: "/v1/messages",
			body: `{"model":"MODEL","messages":[{"role":"user","content":"hello"}],"max_tokens":128}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(strings.ReplaceAll(tc.body, "MODEL", model)))
			req.Header.Set("Authorization", "Bearer test-key")
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusTooManyRequests {
				t.Fatalf("status = %d, want %d; body = %s", w.Code, http.StatusTooManyRequests, w.Body.String())
			}
			if got := w.Header().Get("Retry-After"); got == "" {
				t.Fatal("Retry-After header missing")
			}
			var body struct {
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if body.Error.Code != "rate_limit_exceeded" {
				t.Fatalf("code = %q, want rate_limit_exceeded", body.Error.Code)
			}
		})
	}
}

func TestMaybeFallbackAliasTTFTSwitchesToPrevious(t *testing.T) {
	srv, _ := testServer(t)
	publicModel := "public-ttft-alias"
	desired := "desired-ttft-build"
	previous := "previous-ttft-build"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: desired, SizeGB: 1, MinRAMGB: 24},
		{ID: previous, SizeGB: 1, MinRAMGB: 24},
	})
	srv.registry.SetModelAliases(map[string]registry.AliasTarget{
		publicModel: {Desired: desired, Previous: previous},
	})

	desiredProvider := registerBuildsProvider(srv, "desired-slow", desired)
	desiredProvider.Mu().Lock()
	desiredProvider.DecodeTPS = 100
	desiredProvider.PrefillTPS = 400
	desiredProvider.BackendCapacity.Slots[0].MaxTokensPotential = 2_000
	desiredProvider.Mu().Unlock()

	previousProvider := registerBuildsProvider(srv, "previous-fast", previous)
	previousProvider.Mu().Lock()
	previousProvider.DecodeTPS = 100
	previousProvider.PrefillTPS = 400
	previousProvider.Mu().Unlock()

	parsed := map[string]any{"model": desired}
	fallbackModel, candidates, rejections, tooLarge, bestTTFT, hasTTFT, switched := srv.maybeFallbackAliasTTFT(
		parsed,
		publicModel,
		desired,
		100,
		128,
		registry.RequestTraits{},
		false,
		nil,
	)

	if !switched {
		t.Fatalf("switched = false, candidates=%d rejections=%d tooLarge=%d bestTTFT=%v has=%v", candidates, rejections, tooLarge, bestTTFT, hasTTFT)
	}
	if fallbackModel != previous || parsed["model"] != previous {
		t.Fatalf("fallback model = %q parsed=%v, want previous %q", fallbackModel, parsed["model"], previous)
	}
	if candidates != 1 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("capacity = (%d,%d,%d), want (1,0,0)", candidates, rejections, tooLarge)
	}
	if !hasTTFT || bestTTFT > openRouterTTFT429Threshold {
		t.Fatalf("bestTTFT = %v has=%v, want within threshold", bestTTFT, hasTTFT)
	}
}
