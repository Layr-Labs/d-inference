package api

// Routing-failover integration tests (WS-E).
//
// These tests exercise the reliability contracts being implemented by the
// routing-failover workstreams against a real coordinator (httptest server,
// in-memory store, real registry) and fake WebSocket providers that speak the
// full encrypted protocol:
//
//   - [WS-C] Deferred commit: a boilerplate role-only delta chunk no longer
//     commits the dispatch. A provider error or disconnect BEFORE any
//     content-bearing chunk results in a transparent retry on another
//     provider — invisible to the consumer (200, clean stream, one [DONE]).
//     In-band SSE errors are surfaced ONLY after content has flowed.
//   - [WS-R] Inference-error cooldown, tools version floors, and the
//     template_render_ok routing gate (see failover_routing_integration_test.go).
//   - [WS-T] Tool-schema normalization reaching the provider (see
//     failover_routing_integration_test.go).
//
// The fake-provider harness here follows the established patterns from
// cancellation_integration_test.go / multi_provider_test.go /
// load_integration_test.go: register over /ws/provider with an X25519 key from
// testPublicKeyB64() (keypair cached in testProviderKeys), answer attestation
// challenges with makeValidChallengeResponse, receive the E2E-encrypted
// inference_request, and reply with encrypted inference_response_chunk
// messages (plaintext chunks are rejected by decryptTextResponseChunk) plus
// plaintext inference_error / inference_complete terminals.
//
// Registration is sent as raw JSON (a patched protocol.RegisterMessage map) so
// tests can set fields that are still landing in sibling workstreams (e.g. the
// per-model template_render_ok flag) without this file depending on their
// struct changes to compile.
//
// INTEGRATION-NOTE(WS-C): TestPreContentFailover_* encode the deferred-commit
// contract and FAIL against the pre-workstream coordinator (which commits on
// the role chunk and surfaces an in-band error). They must pass once WS-C
// lands. TestPostContentErrorStillSurfaced and TestBoilerplateThenCleanClose
// pass against the current coordinator and act as regression guards on the
// correctness boundary WS-C must not move.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// ---------------------------------------------------------------------------
// Server setup
// ---------------------------------------------------------------------------

// setupFailoverServer creates a coordinator test server for failover tests,
// mirroring setupTestServer / setupLoadTestServer.
func setupFailoverServer(t *testing.T) (*registry.Registry, *store.MemoryStore, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 500 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return reg, st, ts
}

// ---------------------------------------------------------------------------
// Fake provider actor
// ---------------------------------------------------------------------------

// failoverModelSpec describes one advertised model for a fake provider.
// TemplateRenderOK is emitted as the raw wire field "template_render_ok" —
// the exact bytes a 0.6.5+ Swift provider sends — which keeps these tests
// independent of the Go struct shape (protocol.ModelInfo.TemplateRenderOK
// *bool has landed and decodes this field).
type failoverModelSpec struct {
	ID               string
	TemplateRenderOK *bool
}

// inferenceScript is a fake provider's behavior for one inference dispatch.
// body is the decrypted request body (nil if decryption failed).
type inferenceScript func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte)

// failoverProvider is a scripted fake provider speaking the full WS protocol.
type failoverProvider struct {
	t          *testing.T
	name       string
	conn       *websocket.Conn
	pubKey     string
	privKey    [32]byte
	registryID string
	script     inferenceScript
	dispatches atomic.Int32
	bodies     chan []byte
	done       chan struct{}
	closeOnce  sync.Once
}

type failoverProviderConfig struct {
	Name      string
	Version   string
	DecodeTPS float64
	Models    []failoverModelSpec
	Script    inferenceScript
	// Serial, when non-empty, is stamped onto the provider's AttestationResult
	// after registration so a request carrying a provider_serials allowlist can
	// constrain routing to (or away from) this provider — mirroring the
	// allowlist-aware capability fast-fails and QuickCapacityCheck.
	Serial string
}

// startFailoverProvider dials the provider WebSocket, registers (raw-JSON
// register message patched from a protocol.RegisterMessage), marks the new
// provider hardware-trusted + challenge-verified, and starts the read loop.
func startFailoverProvider(t *testing.T, ctx context.Context, ts *httptest.Server, reg *registry.Registry, cfg failoverProviderConfig) *failoverProvider {
	t.Helper()

	pubKey := testPublicKeyB64()
	v, ok := testProviderKeys.Load(pubKey)
	if !ok {
		t.Fatalf("provider %s: missing cached keypair for %q", cfg.Name, pubKey)
	}
	keypair := v.(testProviderKeyPair)

	before := make(map[string]struct{})
	for _, id := range reg.ProviderIDs() {
		before[id] = struct{}{}
	}

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("provider %s: websocket dial: %v", cfg.Name, err)
	}

	// Build the register message from the canonical struct, then patch the
	// models entries in as raw maps so per-model fields still landing in
	// sibling workstreams (template_render_ok) can be set by tests.
	regStruct := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Backend:                 "mlx-swift",
		Version:                 cfg.Version,
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		DecodeTPS:               cfg.DecodeTPS,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	rawReg, err := json.Marshal(regStruct)
	if err != nil {
		t.Fatalf("provider %s: marshal register struct: %v", cfg.Name, err)
	}
	var regMap map[string]any
	if err := json.Unmarshal(rawReg, &regMap); err != nil {
		t.Fatalf("provider %s: unmarshal register struct: %v", cfg.Name, err)
	}
	modelEntries := make([]map[string]any, 0, len(cfg.Models))
	for _, m := range cfg.Models {
		entry := map[string]any{
			"id":           m.ID,
			"size_bytes":   int64(1000),
			"model_type":   "chat",
			"quantization": "4bit",
		}
		if m.TemplateRenderOK != nil {
			entry["template_render_ok"] = *m.TemplateRenderOK
		}
		modelEntries = append(modelEntries, entry)
	}
	regMap["models"] = modelEntries
	regData, err := json.Marshal(regMap)
	if err != nil {
		t.Fatalf("provider %s: marshal register message: %v", cfg.Name, err)
	}
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("provider %s: write register: %v", cfg.Name, err)
	}

	// Let registration process, then identify and trust the new provider.
	time.Sleep(200 * time.Millisecond)
	registryID := ""
	for _, id := range reg.ProviderIDs() {
		if _, existed := before[id]; !existed {
			registryID = id
			break
		}
	}
	if registryID == "" {
		t.Fatalf("provider %s: did not appear in registry after register", cfg.Name)
	}
	reg.SetTrustLevel(registryID, registry.TrustHardware)
	reg.RecordChallengeSuccess(registryID)

	// Stamp an attested serial so provider_serials allowlist routing can target
	// or exclude this provider (providerMatchesAllowedSerial reads
	// AttestationResult.SerialNumber / MDAResult.DeviceSerial).
	if cfg.Serial != "" {
		if p := reg.GetProvider(registryID); p != nil {
			p.SetAttestationResult(&attestation.VerificationResult{
				Valid:        true,
				SerialNumber: cfg.Serial,
			})
		}
	}

	fp := &failoverProvider{
		t:          t,
		name:       cfg.Name,
		conn:       conn,
		pubKey:     pubKey,
		privKey:    keypair.private,
		registryID: registryID,
		script:     cfg.Script,
		bodies:     make(chan []byte, 8),
		done:       make(chan struct{}),
	}
	go fp.run(ctx)
	t.Cleanup(fp.close)
	return fp
}

// run reads coordinator messages: answers attestation challenges, counts and
// dispatches inference requests to the script. Returns on connection close.
func (fp *failoverProvider) run(ctx context.Context) {
	defer close(fp.done)
	for {
		_, data, err := fp.conn.Read(ctx)
		if err != nil {
			return
		}
		var env struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &env); err != nil {
			continue
		}
		switch env.Type {
		case protocol.TypeAttestationChallenge:
			resp := makeValidChallengeResponse(data, fp.pubKey)
			if err := fp.conn.Write(ctx, websocket.MessageText, resp); err != nil {
				return
			}
		case protocol.TypeInferenceRequest:
			var req protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &req); err != nil {
				continue
			}
			fp.dispatches.Add(1)
			body := fp.decryptBody(req)
			select {
			case fp.bodies <- body:
			default:
			}
			if fp.script != nil {
				fp.script(ctx, fp, req, body)
			}
		}
	}
}

// decryptBody decrypts the E2E-encrypted request body with the provider's
// X25519 private key (nil on failure).
func (fp *failoverProvider) decryptBody(req protocol.InferenceRequestMessage) []byte {
	if req.EncryptedBody == nil {
		fp.t.Logf("provider %s: inference request %s missing encrypted body", fp.name, req.RequestID)
		return nil
	}
	payload := &e2e.EncryptedPayload{
		EphemeralPublicKey: req.EncryptedBody.EphemeralPublicKey,
		Ciphertext:         req.EncryptedBody.Ciphertext,
	}
	plaintext, err := e2e.DecryptWithPrivateKey(payload, fp.privKey)
	if err != nil {
		fp.t.Logf("provider %s: decrypt request body: %v", fp.name, err)
		return nil
	}
	return plaintext
}

func (fp *failoverProvider) dispatchCount() int {
	return int(fp.dispatches.Load())
}

// close shuts the provider WebSocket down (idempotent; safe in t.Cleanup).
func (fp *failoverProvider) close() {
	fp.closeOnce.Do(func() {
		_ = fp.conn.Close(websocket.StatusNormalClosure, "test done")
	})
}

// closeNow abruptly drops the provider connection, simulating a crash /
// network drop mid-request (the OpenRouter partner symptom).
func (fp *failoverProvider) closeNow() {
	fp.closeOnce.Do(func() {
		_ = fp.conn.CloseNow()
	})
}

// ---------------------------------------------------------------------------
// Scripted provider behaviors
// ---------------------------------------------------------------------------

// roleOnlyChunkSSE is the OpenAI boilerplate role-only delta chunk every
// backend emits before any content. Per the WS-C contract it must NOT commit
// the dispatch.
func roleOnlyChunkSSE(model string) string {
	return fmt.Sprintf(`data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":%q,"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`+"\n\n", model)
}

func contentChunkSSE(model, text string) string {
	data, _ := json.Marshal(text)
	return fmt.Sprintf(`data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":%q,"choices":[{"index":0,"delta":{"content":%s},"finish_reason":null}]}`+"\n\n", model, data)
}

func (fp *failoverProvider) sendRoleChunk(ctx context.Context, req protocol.InferenceRequestMessage, model string) {
	writeEncryptedTestChunk(fp.t, ctx, fp.conn, req, fp.pubKey, roleOnlyChunkSSE(model))
}

func (fp *failoverProvider) sendContentChunk(ctx context.Context, req protocol.InferenceRequestMessage, model, text string) {
	writeEncryptedTestChunk(fp.t, ctx, fp.conn, req, fp.pubKey, contentChunkSSE(model, text))
}

func (fp *failoverProvider) sendInferenceError(ctx context.Context, req protocol.InferenceRequestMessage, errMsg string, statusCode int) {
	msg := protocol.InferenceErrorMessage{
		Type:       protocol.TypeInferenceError,
		RequestID:  req.RequestID,
		Error:      errMsg,
		StatusCode: statusCode,
	}
	data, _ := json.Marshal(msg)
	if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
		fp.t.Logf("provider %s: write inference_error: %v", fp.name, err)
	}
}

func (fp *failoverProvider) sendComplete(ctx context.Context, req protocol.InferenceRequestMessage, usage protocol.UsageInfo) {
	msg := protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: req.RequestID,
		Usage:     usage,
	}
	data, _ := json.Marshal(msg)
	if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
		fp.t.Logf("provider %s: write inference_complete: %v", fp.name, err)
	}
}

// serveFull streams role + one content chunk carrying marker, then completes.
func (fp *failoverProvider) serveFull(ctx context.Context, req protocol.InferenceRequestMessage, model, marker string) {
	fp.sendRoleChunk(ctx, req, model)
	fp.sendContentChunk(ctx, req, model, marker)
	fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 3})
}

// markerFor returns the content marker a full-serve script emits for a
// provider, so tests can assert WHICH provider's content reached the consumer.
func markerFor(name string) string {
	return "content-from-" + name
}

// fullServeScript serves every dispatch successfully with the provider's marker.
func fullServeScript(model string) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
}

// dispatchRecorder tracks the global order in which providers received
// dispatches, so failover tests are independent of which provider the
// scheduler happens to pick first.
type dispatchRecorder struct {
	mu    sync.Mutex
	order []string
}

func (d *dispatchRecorder) record(name string) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.order = append(d.order, name)
	return len(d.order)
}

func (d *dispatchRecorder) sequence() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make([]string, len(d.order))
	copy(out, d.order)
	return out
}

// failFirstScript makes the provider that receives the globally-FIRST dispatch
// fail pre-content (role-only chunk, then failMode), while every later
// dispatch is served fully. failMode is "error" (inference_error 500) or
// "disconnect" (abrupt WebSocket drop after the role chunk).
func failFirstScript(rec *dispatchRecorder, model, failMode string) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		seq := rec.record(fp.name)
		if seq == 1 {
			fp.sendRoleChunk(ctx, req, model)
			// Let the role chunk relay through the coordinator before the
			// failure signal so the "boilerplate already flowed" ordering is
			// deterministic.
			time.Sleep(40 * time.Millisecond)
			switch failMode {
			case "error":
				fp.sendInferenceError(ctx, req, "simulated backend failure", http.StatusInternalServerError)
			case "disconnect":
				fp.closeNow()
			default:
				fp.t.Errorf("unknown failMode %q", failMode)
			}
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
}

// ---------------------------------------------------------------------------
// Consumer helpers
// ---------------------------------------------------------------------------

// buildChatBody constructs a chat-completions request body. tools (optional)
// is an OpenAI tools array. max_tokens is set explicitly so the scheduler's
// cost model (reqMax/decodeTPS) deterministically prefers high-TPS providers.
func buildChatBody(t *testing.T, model string, stream bool, tools []map[string]any) string {
	t.Helper()
	body := map[string]any{
		"model":      model,
		"messages":   []map[string]any{{"role": "user", "content": "failover test prompt"}},
		"stream":     stream,
		"max_tokens": 64,
	}
	if tools != nil {
		body["tools"] = tools
	}
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal chat body: %v", err)
	}
	return string(data)
}

// postChat sends a chat-completions request and drains the full response.
func postChat(ctx context.Context, tsURL, apiKey, body string) (int, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tsURL+"/v1/chat/completions", strings.NewReader(body))
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

// assertCleanFailoverStream asserts the consumer-visible contract of a
// transparent failover: HTTP 200, the winning provider's content present,
// exactly one [DONE], and no in-band {"error"} event anywhere.
func assertCleanFailoverStream(t *testing.T, status int, body, wantMarker string) {
	t.Helper()
	if status != http.StatusOK {
		t.Errorf("status = %d, want 200; body = %s", status, body)
	}
	if wantMarker != "" && !strings.Contains(body, wantMarker) {
		t.Errorf("stream missing failover content %q; body = %s", wantMarker, body)
	}
	if n := strings.Count(body, "data: [DONE]"); n != 1 {
		t.Errorf("stream has %d [DONE] terminators, want exactly 1; body = %s", n, body)
	}
	if strings.Contains(body, `"error"`) {
		t.Errorf("stream contains an in-band error event — provider failure leaked to the consumer; body = %s", body)
	}
}

// ---------------------------------------------------------------------------
// Test 1: pre-content failover on provider error (streaming)
// ---------------------------------------------------------------------------

// TestPreContentFailover_ErrorAfterRoleChunk: the first-dispatched provider
// sends ONLY the boilerplate role chunk, then an inference_error (500). The
// coordinator must NOT commit on the role chunk: it retries transparently on
// the other provider, and the consumer sees a clean 200 stream with the other
// provider's content, exactly one [DONE], and no in-band error.
//
// INTEGRATION-NOTE(WS-C): fails against the pre-workstream coordinator (role
// chunk commits; error surfaces in-band). Encodes the deferred-commit contract.
func TestPreContentFailover_ErrorAfterRoleChunk(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "failover-error-model"
	rec := &dispatchRecorder{}
	script := failFirstScript(rec, model, "error")

	// DecodeTPS 200 vs 1 puts the providers ~63s apart in scheduler cost
	// (max_tokens=64), far outside the 3s near-tie window — provider A is
	// deterministically dispatched first. The script is order-independent
	// anyway: whoever is dispatched first fails.
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.4", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.4", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}

	seq := rec.sequence()
	if len(seq) != 2 {
		t.Fatalf("dispatch sequence = %v, want exactly 2 dispatches (failed primary + failover winner); status=%d body=%s", seq, status, body)
	}
	if seq[0] == seq[1] {
		t.Errorf("both dispatches went to %q — failover must retry on a DIFFERENT provider", seq[0])
	}
	assertCleanFailoverStream(t, status, body, markerFor(seq[1]))
	if strings.Contains(body, markerFor(seq[0])) {
		t.Errorf("stream contains content from the failed provider %q; body = %s", seq[0], body)
	}
	if got := pA.dispatchCount() + pB.dispatchCount(); got != 2 {
		t.Errorf("total dispatches = %d, want 2", got)
	}
}

// ---------------------------------------------------------------------------
// Test 1b: pre-content failover on provider error (non-streaming)
// ---------------------------------------------------------------------------

// TestPreContentFailover_ErrorAfterRoleChunk_NonStreaming is the stream:false
// variant of Test 1: the assembled JSON response must carry the failover
// winner's content and no error.
//
// INTEGRATION-NOTE(WS-C): same contract dependency as Test 1.
func TestPreContentFailover_ErrorAfterRoleChunk_NonStreaming(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "failover-error-nonstream-model"
	rec := &dispatchRecorder{}
	script := failFirstScript(rec, model, "error")

	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.4", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.4", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", status, body)
	}

	seq := rec.sequence()
	if len(seq) != 2 {
		t.Fatalf("dispatch sequence = %v, want exactly 2 dispatches; body = %s", seq, body)
	}
	if seq[0] == seq[1] {
		t.Errorf("both dispatches went to %q — failover must retry on a DIFFERENT provider", seq[0])
	}

	var resp struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Error any `json:"error"`
	}
	if err := json.Unmarshal([]byte(body), &resp); err != nil {
		t.Fatalf("response is not valid JSON: %v; body = %s", err, body)
	}
	if resp.Error != nil {
		t.Errorf("response contains an error field — provider failure leaked: %s", body)
	}
	if len(resp.Choices) == 0 || !strings.Contains(resp.Choices[0].Message.Content, markerFor(seq[1])) {
		t.Errorf("response content missing failover winner marker %q; body = %s", markerFor(seq[1]), body)
	}
}

// ---------------------------------------------------------------------------
// Test 2: pre-content failover on provider disconnect
// ---------------------------------------------------------------------------

// TestPreContentFailover_DisconnectAfterRoleChunk: identical to Test 1, but
// the first-dispatched provider drops its WebSocket after the role chunk
// instead of sending an error — the exact OpenRouter partner symptom. The
// registry converts the drop into a "provider disconnected" (502) terminal;
// pre-content, that must trigger a transparent retry, not an in-band error.
//
// INTEGRATION-NOTE(WS-C): fails against the pre-workstream coordinator.
func TestPreContentFailover_DisconnectAfterRoleChunk(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "failover-disconnect-model"
	rec := &dispatchRecorder{}
	script := failFirstScript(rec, model, "disconnect")

	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.4", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.4", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}

	seq := rec.sequence()
	if len(seq) != 2 {
		t.Fatalf("dispatch sequence = %v, want exactly 2 dispatches (dropped primary + failover winner); status=%d body=%s", seq, status, body)
	}
	if seq[0] == seq[1] {
		t.Errorf("both dispatches went to %q — failover must retry on a DIFFERENT provider", seq[0])
	}
	assertCleanFailoverStream(t, status, body, markerFor(seq[1]))
	if strings.Contains(body, markerFor(seq[0])) {
		t.Errorf("stream contains content from the dropped provider %q; body = %s", seq[0], body)
	}
}

// ---------------------------------------------------------------------------
// Test 3: post-content errors must STILL surface in-band
// ---------------------------------------------------------------------------

// TestPostContentErrorStillSurfaced guards the correctness boundary of the
// deferred-commit change: once a CONTENT-bearing chunk has flowed to the
// consumer, a provider failure must surface as an in-band error — silently
// retrying on another provider would duplicate/corrupt already-delivered
// output. Provider B is present and healthy specifically so a (buggy)
// post-content retry would be detectable: its marker must NOT appear and it
// must receive no dispatch.
//
// Passes against the current coordinator; must keep passing after WS-C.
func TestPostContentErrorStillSurfaced(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "post-content-error-model"
	const partialContent = "partial-content-before-failure"

	failAfterContent := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendRoleChunk(ctx, req, model)
		fp.sendContentChunk(ctx, req, model, partialContent)
		// Let the content chunk relay before the error terminal.
		time.Sleep(40 * time.Millisecond)
		fp.sendInferenceError(ctx, req, "backend exploded mid-generation", http.StatusInternalServerError)
	}

	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.4", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: failAfterContent,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.4", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200 (stream committed by the content chunk); body = %s", status, body)
	}

	idxContent := strings.Index(body, partialContent)
	idxErr := strings.Index(body, `"provider_error"`)
	if idxContent < 0 {
		t.Errorf("stream missing the pre-failure content chunk %q; body = %s", partialContent, body)
	}
	if idxErr < 0 {
		t.Errorf("stream did NOT surface an in-band error after content had flowed — silent post-content retry is a correctness bug; body = %s", body)
	}
	if idxContent >= 0 && idxErr >= 0 && idxContent > idxErr {
		t.Errorf("in-band error appeared BEFORE the content chunk (content@%d, error@%d); body = %s", idxContent, idxErr, body)
	}
	if strings.Contains(body, markerFor("provider-b")) {
		t.Errorf("stream contains provider-b content — coordinator silently retried AFTER content had flowed; body = %s", body)
	}
	if got := pB.dispatchCount(); got != 0 {
		t.Errorf("provider-b received %d dispatch(es), want 0 — no retry after content has flowed", got)
	}
}

// ---------------------------------------------------------------------------
// Test 8: boilerplate role chunk then clean close
// ---------------------------------------------------------------------------

// TestBoilerplateThenCleanClose guards the held-chunks-then-clean-close edge
// of deferred commit: a provider that sends only the boilerplate role chunk
// and then a clean inference_complete (zero content) must yield a well-formed,
// empty-ish 200 completion — no hang, no in-band error, exactly one [DONE].
//
// Passes against the current coordinator; must keep passing after WS-C (the
// held boilerplate must be committed/flushed on clean close, not retried and
// not abandoned).
func TestBoilerplateThenCleanClose(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "boilerplate-clean-close-model"

	roleThenComplete := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendRoleChunk(ctx, req, model)
		time.Sleep(30 * time.Millisecond)
		fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 0})
	}

	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.4", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: roleThenComplete,
	})

	start := time.Now()
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	elapsed := time.Since(start)

	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", status, body)
	}
	if n := strings.Count(body, "data: [DONE]"); n != 1 {
		t.Errorf("stream has %d [DONE] terminators, want exactly 1; body = %s", n, body)
	}
	if strings.Contains(body, `"error"`) {
		t.Errorf("clean zero-content completion surfaced an error; body = %s", body)
	}
	if got := pA.dispatchCount(); got != 1 {
		t.Errorf("provider received %d dispatch(es), want 1 (clean close must not trigger a retry)", got)
	}
	// Guard the no-hang property well inside the per-test wall budget.
	if elapsed > 8*time.Second {
		t.Errorf("empty completion took %s — held-chunks-then-clean-close is hanging", elapsed)
	}
}
