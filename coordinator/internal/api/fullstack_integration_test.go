package api

// Full-stack integration tests: real coordinator + real vllm-mlx backends.
//
// These tests spin up actual vllm-mlx processes with a small model, connect
// simulated providers to the coordinator via WebSocket (with full E2E
// encryption), and send consumer HTTP requests through the coordinator.
//
// This tests the ENTIRE inference pipeline end-to-end with real GPU inference.
//
// Requirements:
//   - Apple Silicon Mac with vllm-mlx installed
//   - mlx-community/Qwen3.5-0.8B-MLX-4bit downloaded (~0.5GB per instance)
//   - ~1GB RAM per provider instance
//
// Gate: LIVE_FULLSTACK_TEST=1 cargo test (not run in CI)
//
//     LIVE_FULLSTACK_TEST=1 go test ./internal/api/ -run TestFullStack -v -timeout=600s
//

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/e2e"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"golang.org/x/crypto/nacl/box"
	"nhooyr.io/websocket"
)

const (
	// testModel is the small model used for full-stack tests.
	testModel = "mlx-community/Qwen3.5-0.8B-MLX-4bit"

	// basePort is the starting port for vllm-mlx backends.
	basePort = 18200
)

func shouldRunFullStack() bool {
	return os.Getenv("LIVE_FULLSTACK_TEST") == "1"
}

// ---------------------------------------------------------------------------
// vllm-mlx process management
// ---------------------------------------------------------------------------

type backendProcess struct {
	port int
	cmd  *exec.Cmd
}

func startBackend(t *testing.T, model string, port int) *backendProcess {
	return startBackendWithOptions(t, model, port, false)
}

func startBackendWithBatching(t *testing.T, model string, port int) *backendProcess {
	return startBackendWithOptions(t, model, port, true)
}

func startBackendWithOptions(t *testing.T, model string, port int, continuousBatching bool) *backendProcess {
	t.Helper()
	args := []string{"serve", model, "--port", fmt.Sprintf("%d", port)}
	if continuousBatching {
		args = append(args, "--continuous-batching")
	}
	cmd := exec.Command("vllm-mlx", args...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard

	if err := cmd.Start(); err != nil {
		t.Fatalf("failed to start vllm-mlx on port %d: %v", port, err)
	}

	mode := "sequential"
	if continuousBatching {
		mode = "continuous-batching"
	}
	t.Logf("started vllm-mlx PID=%d on port %d (%s)", cmd.Process.Pid, port, mode)
	return &backendProcess{port: port, cmd: cmd}
}

func (b *backendProcess) stop() {
	if b.cmd != nil && b.cmd.Process != nil {
		b.cmd.Process.Kill()
		b.cmd.Wait()
	}
}

func (b *backendProcess) baseURL() string {
	return fmt.Sprintf("http://127.0.0.1:%d", b.port)
}

func waitForBackendHealthy(t *testing.T, url string, timeout time.Duration) {
	t.Helper()
	client := &http.Client{Timeout: 3 * time.Second}
	start := time.Now()
	for {
		if time.Since(start) > timeout {
			t.Fatalf("backend %s did not become healthy within %v", url, timeout)
		}
		resp, err := client.Get(url + "/health")
		if err == nil {
			var body map[string]any
			json.NewDecoder(resp.Body).Decode(&body)
			resp.Body.Close()
			if loaded, _ := body["model_loaded"].(bool); loaded {
				t.Logf("backend %s healthy (%.1fs)", url, time.Since(start).Seconds())
				return
			}
		}
		time.Sleep(2 * time.Second)
	}
}

// ---------------------------------------------------------------------------
// Simulated provider — speaks the full WebSocket protocol with E2E encryption
// ---------------------------------------------------------------------------

type simulatedProvider struct {
	id         string
	port       int    // vllm-mlx backend port
	model      string // model ID to register with
	pubKey     [32]byte
	privKey    [32]byte
	pubKeyB64  string
	conn       *websocket.Conn
	served     int64
	backendURL string
	t          *testing.T
}

func newSimulatedProvider(t *testing.T, backendPort int) *simulatedProvider {
	return newSimulatedProviderWithModel(t, backendPort, testModel)
}

func newSimulatedProviderWithModel(t *testing.T, backendPort int, model string) *simulatedProvider {
	t.Helper()
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("failed to generate X25519 key pair: %v", err)
	}
	return &simulatedProvider{
		id:         fmt.Sprintf("sim-provider-%d", backendPort),
		port:       backendPort,
		model:      model,
		pubKey:     *pub,
		privKey:    *priv,
		pubKeyB64:  base64.StdEncoding.EncodeToString(pub[:]),
		backendURL: fmt.Sprintf("http://127.0.0.1:%d", backendPort),
		t:          t,
	}
}

// connect registers the provider with the coordinator via WebSocket.
func (p *simulatedProvider) connect(ctx context.Context, coordinatorURL string) {
	wsURL := "ws" + strings.TrimPrefix(coordinatorURL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		p.t.Fatalf("provider %s: websocket dial failed: %v", p.id, err)
	}
	conn.SetReadLimit(10 * 1024 * 1024)
	p.conn = conn

	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     128,
		},
		Models: []protocol.ModelInfo{{
			ID:           p.model,
			ModelType:    "chat",
			Quantization: "4bit",
			SizeBytes:    500_000_000,
		}},
		Backend:   "vllm-mlx",
		PublicKey: p.pubKeyB64,
		DecodeTPS: 100.0,
	}
	data, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		p.t.Fatalf("provider %s: register write failed: %v", p.id, err)
	}
}

// run processes messages from the coordinator: challenges and inference requests.
// It forwards real inference requests to the local vllm-mlx backend.
func (p *simulatedProvider) run(ctx context.Context) {
	client := &http.Client{Timeout: 120 * time.Second}

	for {
		_, data, err := p.conn.Read(ctx)
		if err != nil {
			return
		}

		var envelope struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &envelope); err != nil {
			continue
		}

		switch envelope.Type {
		case protocol.TypeAttestationChallenge:
			p.handleChallenge(ctx, data)

		case protocol.TypeInferenceRequest:
			p.handleInferenceRequest(ctx, data, client)
		}
	}
}

func (p *simulatedProvider) handleChallenge(ctx context.Context, data []byte) {
	var challenge protocol.AttestationChallengeMessage
	json.Unmarshal(data, &challenge)

	rdmaDisabled := true
	sipEnabled := true
	secureBootEnabled := true
	resp := protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             challenge.Nonce,
		Signature:         base64.StdEncoding.EncodeToString([]byte("test-sig")),
		PublicKey:         p.pubKeyB64,
		RDMADisabled:      &rdmaDisabled,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
	}
	respData, _ := json.Marshal(resp)
	p.conn.Write(ctx, websocket.MessageText, respData)
}

func (p *simulatedProvider) handleInferenceRequest(ctx context.Context, data []byte, client *http.Client) {
	var msg struct {
		Type      string `json:"type"`
		RequestID string `json:"request_id"`
		// E2E encrypted body
		EncryptedBody *e2e.EncryptedPayload `json:"encrypted_body,omitempty"`
		// Plain body (fallback)
		Body json.RawMessage `json:"body,omitempty"`
	}
	json.Unmarshal(data, &msg)

	// Decrypt the request body
	var reqBody protocol.InferenceRequestBody
	if msg.EncryptedBody != nil {
		plaintext, err := e2e.DecryptWithPrivateKey(msg.EncryptedBody, p.privKey)
		if err != nil {
			p.sendError(ctx, msg.RequestID, fmt.Sprintf("decryption failed: %v", err), 500)
			return
		}
		if err := json.Unmarshal(plaintext, &reqBody); err != nil {
			p.sendError(ctx, msg.RequestID, "invalid decrypted body", 400)
			return
		}
	} else if msg.Body != nil {
		json.Unmarshal(msg.Body, &reqBody)
	}

	// Forward to the real vllm-mlx backend
	backendBody := map[string]any{
		"model":    reqBody.Model,
		"messages": reqBody.Messages,
		"stream":   true,
	}
	if reqBody.MaxTokens != nil {
		backendBody["max_tokens"] = *reqBody.MaxTokens
	}
	if reqBody.Temperature != nil {
		backendBody["temperature"] = *reqBody.Temperature
	}

	bodyJSON, _ := json.Marshal(backendBody)
	endpoint := "/v1/chat/completions"
	if reqBody.Endpoint != "" {
		endpoint = reqBody.Endpoint
	}

	backendReq, err := http.NewRequestWithContext(ctx, "POST",
		p.backendURL+endpoint, strings.NewReader(string(bodyJSON)))
	if err != nil {
		p.sendError(ctx, msg.RequestID, err.Error(), 500)
		return
	}
	backendReq.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(backendReq)
	if err != nil {
		p.sendError(ctx, msg.RequestID, fmt.Sprintf("backend error: %v", err), 502)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		errBody, _ := io.ReadAll(resp.Body)
		p.sendError(ctx, msg.RequestID, string(errBody), resp.StatusCode)
		return
	}

	// Stream SSE chunks back to coordinator
	var promptTokens, completionTokens int
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		sseData := strings.TrimPrefix(line, "data: ")
		if sseData == "[DONE]" {
			break
		}

		// Parse chunk to count tokens
		var chunk map[string]any
		if err := json.Unmarshal([]byte(sseData), &chunk); err == nil {
			if choices, ok := chunk["choices"].([]any); ok && len(choices) > 0 {
				if choice, ok := choices[0].(map[string]any); ok {
					if delta, ok := choice["delta"].(map[string]any); ok {
						if content, ok := delta["content"].(string); ok && content != "" {
							completionTokens++
						}
					}
				}
			}
			// Extract usage if present
			if usage, ok := chunk["usage"].(map[string]any); ok {
				if pt, ok := usage["prompt_tokens"].(float64); ok {
					promptTokens = int(pt)
				}
				if ct, ok := usage["completion_tokens"].(float64); ok {
					completionTokens = int(ct)
				}
			}
		}

		// Forward chunk to coordinator
		chunkMsg := protocol.InferenceResponseChunkMessage{
			Type:      protocol.TypeInferenceResponseChunk,
			RequestID: msg.RequestID,
			Data:      "data: " + sseData + "\n\n",
		}
		chunkData, _ := json.Marshal(chunkMsg)
		if err := p.conn.Write(ctx, websocket.MessageText, chunkData); err != nil {
			return
		}
	}

	// Send completion
	if promptTokens == 0 {
		promptTokens = 10 // estimate
	}
	if completionTokens == 0 {
		completionTokens = 1
	}

	complete := protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: msg.RequestID,
		Usage: protocol.UsageInfo{
			PromptTokens:     promptTokens,
			CompletionTokens: completionTokens,
		},
	}
	completeData, _ := json.Marshal(complete)
	p.conn.Write(ctx, websocket.MessageText, completeData)

	atomic.AddInt64(&p.served, 1)
}

func (p *simulatedProvider) sendError(ctx context.Context, requestID, errMsg string, code int) {
	msg := protocol.InferenceErrorMessage{
		Type:       protocol.TypeInferenceError,
		RequestID:  requestID,
		Error:      errMsg,
		StatusCode: code,
	}
	data, _ := json.Marshal(msg)
	p.conn.Write(ctx, websocket.MessageText, data)
}

func (p *simulatedProvider) requestsServed() int64 {
	return atomic.LoadInt64(&p.served)
}

// ---------------------------------------------------------------------------
// Consumer helper — sends requests through the coordinator
// ---------------------------------------------------------------------------

func consumerRequest(ctx context.Context, coordinatorURL, apiKey, model, prompt string, stream bool) (int, string, error) {
	maxTokens := 20
	temp := 0.0
	body := map[string]any{
		"model":       model,
		"messages":    []map[string]string{{"role": "user", "content": prompt}},
		"stream":      stream,
		"max_tokens":  maxTokens,
		"temperature": temp,
	}
	bodyJSON, _ := json.Marshal(body)

	req, err := http.NewRequestWithContext(ctx, "POST",
		coordinatorURL+"/v1/chat/completions", strings.NewReader(string(bodyJSON)))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(respBody), nil
}

// ============================================================================
// Full-stack tests
// ============================================================================

func TestFullStack_MultiProviderInference(t *testing.T) {
	if !shouldRunFullStack() {
		t.Skip("skipping full-stack test (set LIVE_FULLSTACK_TEST=1 to enable)")
	}

	const numProviders = 5

	// --- Start coordinator ---
	t.Log("=== Starting coordinator ===")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	reg.MinTrustLevel = registry.TrustNone // no attestation for testing
	reg.SetQueue(registry.NewRequestQueue(100, 60*time.Second))
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 30 * time.Second

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	t.Logf("coordinator running at %s", ts.URL)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// --- Start vllm-mlx backends ---
	t.Logf("=== Starting %d vllm-mlx backends ===", numProviders)
	backends := make([]*backendProcess, numProviders)
	for i := 0; i < numProviders; i++ {
		backends[i] = startBackend(t, testModel, basePort+i)
	}
	defer func() {
		t.Log("=== Shutting down backends ===")
		for _, b := range backends {
			b.stop()
		}
	}()

	// Wait for all backends to load the model
	var wg sync.WaitGroup
	for i := 0; i < numProviders; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			waitForBackendHealthy(t, backends[idx].baseURL(), 3*time.Minute)
		}(i)
	}
	wg.Wait()
	t.Log("=== All backends healthy ===")

	// --- Connect simulated providers ---
	t.Logf("=== Connecting %d providers ===", numProviders)
	providers := make([]*simulatedProvider, numProviders)
	for i := 0; i < numProviders; i++ {
		providers[i] = newSimulatedProvider(t, basePort+i)
		providers[i].connect(ctx, ts.URL)
		go providers[i].run(ctx)
	}

	// Wait for registration + first challenge
	time.Sleep(2 * time.Second)

	// Set trust levels (since EIGENINFERENCE_MIN_TRUST=none, self-reported attestation is accepted)
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustSelfSigned)
		reg.RecordChallengeSuccess(id)
		reg.SetClaimsVerifiedForTest(id, true)
	}

	providerCount := reg.ProviderCount()
	t.Logf("=== %d providers registered ===", providerCount)
	if providerCount != numProviders {
		t.Fatalf("expected %d providers, got %d", numProviders, providerCount)
	}

	// --- Test 1: Basic inference through coordinator ---
	t.Log("--- Test 1: Basic inference ---")
	code, body, err := consumerRequest(ctx, ts.URL, "test-key", testModel,
		"What is 2+2? Answer with just the number.", true)
	if err != nil {
		t.Fatalf("basic inference failed: %v", err)
	}
	if code != 200 {
		t.Fatalf("basic inference: status=%d body=%s", code, body)
	}
	if !strings.Contains(body, "data:") {
		t.Fatalf("expected SSE data in response, got: %s", body[:min(len(body), 200)])
	}
	t.Log("basic inference: PASS")

	// --- Test 2: Non-streaming inference ---
	t.Log("--- Test 2: Non-streaming inference ---")
	code, body, err = consumerRequest(ctx, ts.URL, "test-key", testModel,
		"Say hello.", false)
	if err != nil {
		t.Fatalf("non-streaming failed: %v", err)
	}
	if code != 200 {
		t.Fatalf("non-streaming: status=%d body=%s", code, body)
	}
	var nsResp map[string]any
	json.Unmarshal([]byte(body), &nsResp)
	if choices, ok := nsResp["choices"].([]any); !ok || len(choices) == 0 {
		t.Fatalf("non-streaming: missing choices in response: %s", body[:min(len(body), 200)])
	}
	t.Log("non-streaming inference: PASS")

	// --- Test 3: Sequential requests to verify routing ---
	t.Log("--- Test 3: Sequential requests (10) ---")
	for i := 0; i < 10; i++ {
		code, _, err := consumerRequest(ctx, ts.URL, "test-key", testModel,
			fmt.Sprintf("What is %d+%d?", i, i), true)
		if err != nil {
			t.Errorf("sequential request %d failed: %v", i, err)
			continue
		}
		if code != 200 {
			t.Errorf("sequential request %d: status=%d", i, code)
		}
	}
	t.Log("sequential requests: PASS")

	// --- Test 4: Concurrent requests ---
	t.Log("--- Test 4: Concurrent requests (20) ---")
	const concurrentRequests = 20
	var mu sync.Mutex
	results := make(map[int]int) // status code → count

	var cwg sync.WaitGroup
	for i := 0; i < concurrentRequests; i++ {
		cwg.Add(1)
		go func(idx int) {
			defer cwg.Done()
			code, _, err := consumerRequest(ctx, ts.URL, "test-key", testModel,
				fmt.Sprintf("Quick: what is %d*2?", idx), true)
			if err != nil {
				mu.Lock()
				results[-1]++
				mu.Unlock()
				return
			}
			mu.Lock()
			results[code]++
			mu.Unlock()
		}(i)
	}
	cwg.Wait()

	t.Logf("concurrent results: %v", results)
	successCount := results[200]
	if successCount < concurrentRequests/2 {
		t.Errorf("expected at least %d/20 concurrent requests to succeed, got %d",
			concurrentRequests/2, successCount)
	}
	t.Log("concurrent requests: PASS")

	// --- Test 5: Load distribution ---
	t.Log("--- Test 5: Load distribution ---")
	var totalServed int64
	for i, p := range providers {
		served := p.requestsServed()
		totalServed += served
		t.Logf("  provider %d (port %d): %d requests served", i, p.port, served)
	}
	t.Logf("  total requests served across all providers: %d", totalServed)

	// At least some providers should have served requests
	activeProviders := 0
	for _, p := range providers {
		if p.requestsServed() > 0 {
			activeProviders++
		}
	}
	if activeProviders == 0 {
		t.Error("no providers served any requests!")
	}
	t.Logf("  %d/%d providers served at least one request", activeProviders, numProviders)
	t.Log("load distribution: PASS")

	// --- Test 6: Provider disconnect + recovery ---
	t.Log("--- Test 6: Provider disconnect ---")
	// Disconnect provider 0
	providers[0].conn.Close(websocket.StatusNormalClosure, "test disconnect")
	time.Sleep(500 * time.Millisecond)

	if reg.ProviderCount() != numProviders-1 {
		t.Errorf("after disconnect: expected %d providers, got %d", numProviders-1, reg.ProviderCount())
	}

	// Requests should still work (routed to remaining providers)
	code, _, err = consumerRequest(ctx, ts.URL, "test-key", testModel,
		"Are you still there?", true)
	if err != nil {
		t.Fatalf("post-disconnect request failed: %v", err)
	}
	if code != 200 {
		t.Errorf("post-disconnect request: status=%d", code)
	}
	t.Log("provider disconnect: PASS")

	// --- Test 7: Reconnect a new provider ---
	t.Log("--- Test 7: Provider reconnect ---")
	newProvider := newSimulatedProvider(t, basePort) // reuse port 0's backend
	newProvider.connect(ctx, ts.URL)
	go newProvider.run(ctx)

	time.Sleep(1 * time.Second)
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustSelfSigned)
		reg.RecordChallengeSuccess(id)
		reg.SetClaimsVerifiedForTest(id, true)
	}

	if reg.ProviderCount() != numProviders {
		t.Errorf("after reconnect: expected %d providers, got %d", numProviders, reg.ProviderCount())
	}

	code, _, err = consumerRequest(ctx, ts.URL, "test-key", testModel,
		"Hello from reconnected provider", true)
	if err != nil {
		t.Fatalf("post-reconnect request failed: %v", err)
	}
	if code != 200 {
		t.Errorf("post-reconnect request: status=%d", code)
	}
	t.Log("provider reconnect: PASS")

	// --- Test 8: Model not available ---
	t.Log("--- Test 8: Model not available ---")
	code, body, _ = consumerRequest(ctx, ts.URL, "test-key", "nonexistent-model-xyz",
		"hello", true)
	if code == 200 {
		t.Error("request for nonexistent model should not succeed")
	}
	t.Logf("nonexistent model: status=%d (expected 404 or 503)", code)
	t.Log("model not available: PASS")

	// --- Test 9: Rapid fire burst ---
	t.Log("--- Test 9: Rapid fire burst (50 requests) ---")
	burstStart := time.Now()
	var burstSuccess int32
	var bwg sync.WaitGroup
	for i := 0; i < 50; i++ {
		bwg.Add(1)
		go func(idx int) {
			defer bwg.Done()
			code, _, err := consumerRequest(ctx, ts.URL, "test-key", testModel,
				"hi", true)
			if err == nil && code == 200 {
				atomic.AddInt32(&burstSuccess, 1)
			}
		}(i)
	}
	bwg.Wait()
	burstDuration := time.Since(burstStart)
	bs := atomic.LoadInt32(&burstSuccess)
	t.Logf("burst: %d/50 succeeded in %.1fs (%.0f req/s)", bs, burstDuration.Seconds(),
		float64(bs)/burstDuration.Seconds())
	if bs < 25 {
		t.Errorf("expected at least 25/50 burst requests to succeed, got %d", bs)
	}
	t.Log("rapid fire burst: PASS")

	// --- Final stats ---
	t.Log("=== Final provider stats ===")
	totalServed = 0
	for i, p := range providers {
		served := p.requestsServed()
		totalServed += served
		t.Logf("  provider %d (port %d): %d requests", i, p.port, served)
	}
	t.Logf("  reconnected provider: %d requests", newProvider.requestsServed())
	totalServed += newProvider.requestsServed()
	t.Logf("  TOTAL: %d requests served across %d providers", totalServed, numProviders)
	t.Log("=== ALL FULL-STACK TESTS PASSED ===")
}

func TestFullStack_TenProviderStress(t *testing.T) {
	if !shouldRunFullStack() {
		t.Skip("skipping full-stack test (set LIVE_FULLSTACK_TEST=1 to enable)")
	}

	const numProviders = 10

	t.Logf("=== 10-PROVIDER STRESS TEST ===")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	reg.MinTrustLevel = registry.TrustNone
	reg.SetQueue(registry.NewRequestQueue(200, 60*time.Second))
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 30 * time.Second

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	// Start 10 backends
	t.Logf("starting %d vllm-mlx backends (ports %d-%d)...", numProviders, basePort, basePort+numProviders-1)
	backends := make([]*backendProcess, numProviders)
	for i := 0; i < numProviders; i++ {
		backends[i] = startBackend(t, testModel, basePort+i)
	}
	defer func() {
		for _, b := range backends {
			b.stop()
		}
	}()

	// Wait for all to be healthy (in parallel)
	t.Log("waiting for all backends to load model...")
	var wg sync.WaitGroup
	for i := 0; i < numProviders; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			waitForBackendHealthy(t, backends[idx].baseURL(), 3*time.Minute)
		}(i)
	}
	wg.Wait()
	t.Log("all 10 backends healthy")

	// Connect all providers
	providers := make([]*simulatedProvider, numProviders)
	for i := 0; i < numProviders; i++ {
		providers[i] = newSimulatedProvider(t, basePort+i)
		providers[i].connect(ctx, ts.URL)
		go providers[i].run(ctx)
	}

	time.Sleep(2 * time.Second)
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustSelfSigned)
		reg.RecordChallengeSuccess(id)
		reg.SetClaimsVerifiedForTest(id, true)
	}

	t.Logf("%d providers registered", reg.ProviderCount())
	if reg.ProviderCount() != numProviders {
		t.Fatalf("expected %d providers, got %d", numProviders, reg.ProviderCount())
	}

	// Send 100 concurrent requests
	t.Log("sending 100 concurrent requests...")
	start := time.Now()
	var success int32
	var cwg sync.WaitGroup
	for i := 0; i < 100; i++ {
		cwg.Add(1)
		go func(idx int) {
			defer cwg.Done()
			code, _, err := consumerRequest(ctx, ts.URL, "test-key", testModel,
				fmt.Sprintf("What is %d+1?", idx), true)
			if err == nil && code == 200 {
				atomic.AddInt32(&success, 1)
			}
		}(i)
	}
	cwg.Wait()
	elapsed := time.Since(start)

	s := atomic.LoadInt32(&success)
	t.Logf("100 concurrent requests: %d succeeded in %.1fs (%.1f req/s)",
		s, elapsed.Seconds(), float64(s)/elapsed.Seconds())

	// Print per-provider distribution
	t.Log("--- per-provider distribution ---")
	var total int64
	for i, p := range providers {
		served := p.requestsServed()
		total += served
		bar := strings.Repeat("#", int(served))
		t.Logf("  provider %02d (:%d): %3d requests %s", i, p.port, served, bar)
	}
	t.Logf("  TOTAL: %d requests across %d providers", total, numProviders)

	if s < 50 {
		t.Errorf("expected at least 50/100 requests to succeed, got %d", s)
	}

	// Count how many providers served at least 1 request
	active := 0
	for _, p := range providers {
		if p.requestsServed() > 0 {
			active++
		}
	}
	t.Logf("  %d/%d providers were active", active, numProviders)
	if active < 2 {
		t.Errorf("expected at least 2 active providers, got %d", active)
	}

	t.Log("=== 10-PROVIDER STRESS TEST PASSED ===")
}

// TestFullStack_ContinuousBatching compares sequential vs continuous-batching
// throughput. Runs 3 providers with batching enabled, blasts 60 concurrent
// requests, and measures whether batching actually improves throughput.
func TestFullStack_ContinuousBatching(t *testing.T) {
	if !shouldRunFullStack() {
		t.Skip("skipping full-stack test (set LIVE_FULLSTACK_TEST=1 to enable)")
	}

	const numProviders = 3
	const numRequests = 60

	// ---------------------------------------------------------------
	// Phase 1: Sequential mode (no batching) — baseline
	// ---------------------------------------------------------------
	t.Log("=== PHASE 1: SEQUENTIAL MODE (baseline) ===")
	seqResults := runBatchingBenchmark(t, numProviders, numRequests, false)

	// ---------------------------------------------------------------
	// Phase 2: Continuous batching mode
	// ---------------------------------------------------------------
	t.Log("=== PHASE 2: CONTINUOUS BATCHING MODE ===")
	batchResults := runBatchingBenchmark(t, numProviders, numRequests, true)

	// ---------------------------------------------------------------
	// Comparison
	// ---------------------------------------------------------------
	t.Log("=== COMPARISON ===")
	t.Logf("  Sequential:  %d/%d succeeded in %.1fs (%.1f req/s)",
		seqResults.success, numRequests, seqResults.duration.Seconds(), seqResults.reqPerSec)
	t.Logf("  Batching:    %d/%d succeeded in %.1fs (%.1f req/s)",
		batchResults.success, numRequests, batchResults.duration.Seconds(), batchResults.reqPerSec)

	if batchResults.reqPerSec > seqResults.reqPerSec {
		speedup := batchResults.reqPerSec / seqResults.reqPerSec
		t.Logf("  Batching is %.1fx faster", speedup)
	} else {
		t.Logf("  Batching did NOT improve throughput (may need more concurrent load or larger model)")
	}

	t.Log("=== CONTINUOUS BATCHING TEST PASSED ===")
}

type benchmarkResult struct {
	success     int
	duration    time.Duration
	reqPerSec   float64
	perProvider []int64
}

func runBatchingBenchmark(t *testing.T, numProviders, numRequests int, continuousBatching bool) benchmarkResult {
	t.Helper()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	reg.MinTrustLevel = registry.TrustNone
	reg.SetQueue(registry.NewRequestQueue(200, 120*time.Second))
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 60 * time.Second

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Use a different port range so sequential and batching don't conflict
	portOffset := 0
	if continuousBatching {
		portOffset = 100
	}

	// Start backends
	backends := make([]*backendProcess, numProviders)
	for i := 0; i < numProviders; i++ {
		port := basePort + portOffset + i
		backends[i] = startBackendWithOptions(t, testModel, port, continuousBatching)
	}
	defer func() {
		for _, b := range backends {
			b.stop()
		}
	}()

	// Wait for healthy
	var wg sync.WaitGroup
	for i := 0; i < numProviders; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			waitForBackendHealthy(t, backends[idx].baseURL(), 3*time.Minute)
		}(i)
	}
	wg.Wait()

	// Warmup each backend
	client := &http.Client{Timeout: 60 * time.Second}
	for i := 0; i < numProviders; i++ {
		warmupBody := `{"model":"` + testModel + `","messages":[{"role":"user","content":"hi"}],"max_tokens":1,"stream":false}`
		resp, err := client.Post(backends[i].baseURL()+"/v1/chat/completions", "application/json",
			strings.NewReader(warmupBody))
		if err == nil {
			io.ReadAll(resp.Body)
			resp.Body.Close()
		}
	}
	t.Log("backends warmed up")

	// Connect providers
	providers := make([]*simulatedProvider, numProviders)
	for i := 0; i < numProviders; i++ {
		port := basePort + portOffset + i
		providers[i] = newSimulatedProvider(t, port)
		providers[i].connect(ctx, ts.URL)
		go providers[i].run(ctx)
	}

	time.Sleep(2 * time.Second)
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustSelfSigned)
		reg.RecordChallengeSuccess(id)
		reg.SetClaimsVerifiedForTest(id, true)
	}

	if reg.ProviderCount() != numProviders {
		t.Fatalf("expected %d providers, got %d", numProviders, reg.ProviderCount())
	}

	// Blast concurrent requests
	mode := "sequential"
	if continuousBatching {
		mode = "continuous-batching"
	}
	t.Logf("sending %d concurrent requests (%s)...", numRequests, mode)

	start := time.Now()
	var success int32
	var cwg sync.WaitGroup
	for i := 0; i < numRequests; i++ {
		cwg.Add(1)
		go func(idx int) {
			defer cwg.Done()
			code, _, err := consumerRequest(ctx, ts.URL, "test-key", testModel,
				fmt.Sprintf("What is %d+1? Answer with just the number.", idx), true)
			if err == nil && code == 200 {
				atomic.AddInt32(&success, 1)
			}
		}(i)
	}
	cwg.Wait()
	elapsed := time.Since(start)

	s := int(atomic.LoadInt32(&success))
	rps := float64(s) / elapsed.Seconds()
	t.Logf("  %d/%d succeeded in %.1fs (%.1f req/s)", s, numRequests, elapsed.Seconds(), rps)

	perProvider := make([]int64, numProviders)
	for i, p := range providers {
		served := p.requestsServed()
		perProvider[i] = served
		bar := strings.Repeat("#", int(served))
		t.Logf("  provider %d (:%d): %3d requests %s", i, backends[i].port, served, bar)
	}

	return benchmarkResult{
		success:     s,
		duration:    elapsed,
		reqPerSec:   rps,
		perProvider: perProvider,
	}
}

// TestFullStack_LargeModelInference tests with a 27B model for cold start timing,
// memory pressure, and generation quality. Requires the model to be downloaded.
//
//	LIVE_FULLSTACK_TEST=1 go test ./internal/api/ -run TestFullStack_LargeModel -v -timeout=600s
func TestFullStack_LargeModelInference(t *testing.T) {
	if !shouldRunFullStack() {
		t.Skip("skipping full-stack test (set LIVE_FULLSTACK_TEST=1 to enable)")
	}

	// Check if a large model is available
	// Prefer the 7B model — loads in ~10s. The 35B+ models take 5+ minutes.
	largeModels := []string{
		"mlx-community/Qwen2.5-7B-Instruct-4bit",
		"mlx-community/Qwen3.5-35B-A3B-8bit",
	}

	var selectedModel string
	homeDir, _ := os.UserHomeDir()
	for _, m := range largeModels {
		dirName := "models--" + strings.ReplaceAll(m, "/", "--")
		if _, err := os.Stat(homeDir + "/.cache/huggingface/hub/" + dirName); err == nil {
			selectedModel = m
			break
		}
	}
	if selectedModel == "" {
		t.Skip("no large model available for testing")
	}

	t.Logf("=== LARGE MODEL TEST: %s ===", selectedModel)

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	reg.MinTrustLevel = registry.TrustNone
	reg.SetQueue(registry.NewRequestQueue(10, 120*time.Second))
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 60 * time.Second

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()

	const port = 18250

	// Start backend with the large model
	t.Log("starting vllm-mlx with large model (this may take 30-60s)...")
	coldStartTime := time.Now()
	backend := startBackend(t, selectedModel, port)
	defer backend.stop()

	waitForBackendHealthy(t, backend.baseURL(), 5*time.Minute)
	coldStartDuration := time.Since(coldStartTime)
	t.Logf("cold start: %.1fs", coldStartDuration.Seconds())

	// Warmup
	t.Log("warming up...")
	warmupStart := time.Now()
	client := &http.Client{Timeout: 120 * time.Second}
	warmupBody := `{"model":"` + selectedModel + `","messages":[{"role":"user","content":"hi"}],"max_tokens":1,"stream":false}`
	resp, err := client.Post(backend.baseURL()+"/v1/chat/completions", "application/json",
		strings.NewReader(warmupBody))
	if err != nil {
		t.Fatalf("warmup failed: %v", err)
	}
	io.ReadAll(resp.Body)
	resp.Body.Close()
	t.Logf("warmup: %.1fs", time.Since(warmupStart).Seconds())

	// Connect provider with the selected model
	provider := newSimulatedProviderWithModel(t, port, selectedModel)
	provider.connect(ctx, ts.URL)
	go provider.run(ctx)
	time.Sleep(2 * time.Second)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustSelfSigned)
		reg.RecordChallengeSuccess(id)
		reg.SetClaimsVerifiedForTest(id, true)
	}

	// Test 1: Quality test — can the model do basic reasoning?
	t.Log("--- quality test ---")
	code, body, err := consumerRequest(ctx, ts.URL, "test-key", selectedModel,
		"What is the capital of Japan? Answer in one word.", true)
	if err != nil {
		t.Fatalf("quality test failed: %v", err)
	}
	if code != 200 {
		t.Fatalf("quality test: status=%d body=%s", code, body[:min(len(body), 200)])
	}
	if strings.Contains(strings.ToLower(body), "tokyo") {
		t.Log("quality test: model correctly answered 'Tokyo'")
	} else {
		t.Logf("quality test: response=%s", body[:min(len(body), 200)])
	}

	// Test 2: Latency benchmark
	t.Log("--- latency benchmark (5 requests) ---")
	var totalLatency time.Duration
	for i := 0; i < 5; i++ {
		reqStart := time.Now()
		code, _, err := consumerRequest(ctx, ts.URL, "test-key", selectedModel,
			fmt.Sprintf("What is %d+%d? Just the number.", i+1, i+2), true)
		latency := time.Since(reqStart)
		totalLatency += latency
		if err != nil || code != 200 {
			t.Logf("  request %d: error (status=%d)", i, code)
		} else {
			t.Logf("  request %d: %.1fs", i, latency.Seconds())
		}
	}
	avgLatency := totalLatency / 5
	t.Logf("  average latency: %.1fs", avgLatency.Seconds())

	// Test 3: Concurrent requests on large model
	t.Log("--- concurrent requests (3) ---")
	var cwg sync.WaitGroup
	var success int32
	for i := 0; i < 3; i++ {
		cwg.Add(1)
		go func(idx int) {
			defer cwg.Done()
			code, _, err := consumerRequest(ctx, ts.URL, "test-key", selectedModel,
				fmt.Sprintf("Say '%d'", idx), true)
			if err == nil && code == 200 {
				atomic.AddInt32(&success, 1)
			}
		}(i)
	}
	cwg.Wait()
	t.Logf("concurrent: %d/3 succeeded", atomic.LoadInt32(&success))

	t.Logf("=== LARGE MODEL TEST COMPLETE (cold_start=%.0fs, avg_latency=%.1fs) ===",
		coldStartDuration.Seconds(), avgLatency.Seconds())
}
