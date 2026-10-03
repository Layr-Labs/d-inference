package inference_test

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
//   - [WS-R] Inference-error cooldown and the template_render_ok routing
//     gate (see failover_routing_integration_test.go).
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

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

// ---------------------------------------------------------------------------
// Server setup
// ---------------------------------------------------------------------------

// setupFailoverServer creates a coordinator test server for failover tests,
// mirroring setupTestServer / setupLoadTestServer.
func setupFailoverServer(t *testing.T) (*registry.Registry, *memory.MemoryStore, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{FirstContentSLAAccounts: []string{testConsumerID}}, logger)
	t.Cleanup(srv.Close)
	srv.SetChallengeInterval(500 * time.Millisecond)
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
	t               *testing.T
	name            string
	conn            *websocket.Conn
	pubKey          string
	privKey         [32]byte
	registryID      string
	script          inferenceScript
	quoteScript     func(context.Context, *failoverProvider, protocol.CapacityProbeMessage)
	dispatches      atomic.Int32
	bodies          chan []byte
	done            chan struct{}
	closeOnce       sync.Once
	appAttestFrames chan protocol.AppAttestShadowPayload
}

type failoverProviderConfig struct {
	AuthToken       string
	Name            string
	Version         string
	DecodeTPS       float64
	Models          []failoverModelSpec
	Script          inferenceScript
	QuoteScript     func(context.Context, *failoverProvider, protocol.CapacityProbeMessage)
	AppAttestFrames chan protocol.AppAttestShadowPayload
}

// startFailoverProvider dials the provider WebSocket, registers (raw-JSON
// register message patched from a protocol.RegisterMessage), and starts the
// read loop. It returns once registration setup finishes and the new provider
// is marked hardware-trusted + challenge-verified.
func startFailoverProvider(t *testing.T, ctx context.Context, ts *httptest.Server, reg *registry.Registry, cfg failoverProviderConfig) *failoverProvider {
	t.Helper()

	pubKey := testkit.PublicKeyB64()
	v, ok := testkit.ProviderKeys.
		Load(pubKey)
	if !ok {
		t.Fatalf("provider %s: missing cached keypair for %q", cfg.Name, pubKey)
	}
	keypair := v.(testkit.ProviderKeyPair)

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("provider %s: websocket dial: %v", cfg.Name, err)
	}

	// Build the register message from the canonical struct, then patch the
	// models entries in as raw maps so per-model fields still landing in
	// sibling workstreams (template_render_ok) can be set by tests.
	regStruct := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		AuthToken: cfg.AuthToken,
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
		PrivacyCapabilities:     testkit.PrivacyCaps(),
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

	fp := &failoverProvider{
		t:               t,
		name:            cfg.Name,
		conn:            conn,
		pubKey:          pubKey,
		privKey:         keypair.Private,
		script:          cfg.Script,
		quoteScript:     cfg.QuoteScript,
		bodies:          make(chan []byte, 8),
		done:            make(chan struct{}),
		appAttestFrames: cfg.AppAttestFrames,
	}
	t.Cleanup(fp.close)
	registered := make(chan error, 1)
	go fp.run(ctx, func() {
		// desired_models follows attestation, account linkage, and runtime
		// setup. Registry presence alone precedes those writes and is too early.
		for _, id := range reg.ProviderIDs() {
			p := reg.GetProvider(id)
			if p == nil {
				continue
			}
			p.Mu().Lock()
			matches := p.PublicKey == pubKey
			p.Mu().Unlock()
			if matches {
				fp.registryID = id
				reg.SetTrustLevel(id, registry.TrustHardware)
				reg.RecordChallengeSuccess(id)
				registered <- nil
				return
			}
		}
		registered <- fmt.Errorf("did not appear in registry after desired_models")
	})
	readyCtx, readyCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readyCancel()
	select {
	case err := <-registered:
		if err != nil {
			t.Fatalf("provider %s: registration: %v", cfg.Name, err)
		}
	case <-fp.done:
		t.Fatalf("provider %s: connection closed before registration completed", cfg.Name)
	case <-readyCtx.Done():
		t.Fatalf("provider %s: waiting for registration: %v", cfg.Name, readyCtx.Err())
	}
	return fp
}

// run reads coordinator messages: answers attestation challenges, counts and
// dispatches inference requests to the script. The first desired_models frame
// signals registration readiness before any challenge response is sent.
// Returns on connection close.
func (fp *failoverProvider) run(ctx context.Context, onRegistered func()) {
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
		case protocol.TypeDesiredModels:
			if onRegistered != nil {
				onRegistered()
				onRegistered = nil
			}
		case protocol.TypeAppAttestShadow:
			if fp.appAttestFrames != nil {
				var message protocol.AppAttestShadowMessage
				if json.Unmarshal(data, &message) == nil {
					select {
					case fp.appAttestFrames <- message.Payload:
					case <-ctx.Done():
						return
					}
				}
			}
		case protocol.TypeAttestationChallenge:
			resp := testkit.MakeValidChallengeResponse(data, fp.pubKey)
			if err := fp.conn.Write(ctx, websocket.MessageText, resp); err != nil {
				return
			}
		case protocol.TypeCapacityProbe:
			var probe protocol.CapacityProbeMessage
			if fp.quoteScript != nil && json.Unmarshal(data, &probe) == nil {
				fp.quoteScript(ctx, fp, probe)
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
	testkit.WriteEncryptedChunk(fp.t, ctx, fp.conn, req, fp.pubKey, roleOnlyChunkSSE(model))
}

func (fp *failoverProvider) sendContentChunk(ctx context.Context, req protocol.InferenceRequestMessage, model, text string) {
	testkit.WriteEncryptedChunk(fp.t, ctx, fp.conn, req, fp.pubKey, contentChunkSSE(model, text))
}

func (fp *failoverProvider) sendAccepted(ctx context.Context, req protocol.InferenceRequestMessage) {
	data, _ := json.Marshal(protocol.InferenceAcceptedMessage{
		Type:      protocol.TypeInferenceAccepted,
		RequestID: req.RequestID,
	})
	if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
		fp.t.Logf("provider %s: write inference_accepted: %v", fp.name, err)
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

// ---------------------------------------------------------------------------
// Test 1b: pre-content failover on provider error (non-streaming)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Test 2: pre-content failover on provider disconnect
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Test 3: post-content errors must STILL surface in-band
// ---------------------------------------------------------------------------

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

// TestReputationLatencyMeasuredToContentEndToEnd exercises the full dispatch
// path end to end: a provider that sends the role-only preamble immediately but
// stalls before real content must have its reputation latency reflect the
// CONTENT arrival, not the (near-instant) preamble. This is the integration
// counterpart to the contentLatency / adjustLatencyForPrefill unit tests, and it
// confirms the dispatch goroutine actually records the sample at commit.
func TestReputationLatencyMeasuredToContentEndToEnd(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "latency-e2e-model"
	const contentDelay = 350 * time.Millisecond

	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendRoleChunk(ctx, req, model)          // held preamble, ~immediate
		time.Sleep(contentDelay)                   // stall before real content
		fp.sendContentChunk(ctx, req, model, "hi") // first content commits
		fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1})
	}
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "lat-e2e", Version: "0.6.4", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", status, body)
	}

	p := reg.GetProvider(pA.registryID)
	if p == nil {
		t.Fatal("provider missing after request")
	}
	// First sample seeds the EWMA. It must reflect the content arrival (>= the
	// stall), not the ~immediate preamble. A generous lower bound keeps this
	// non-flaky while still failing the old behavior, which measured the preamble
	// at a few milliseconds. (No PrefillTPS reported + 5 prompt tokens → prefill
	// adjustment is negligible.)
	if got := p.Reputation.AvgResponseTime; got < contentDelay-100*time.Millisecond {
		t.Fatalf("reputation latency = %v, want >= ~%v (measured to content, not the immediate preamble)", got, contentDelay)
	}
}

// ---------------------------------------------------------------------------
// C1: deterministic client-shape 4xx must stop after ONE dispatch
// ---------------------------------------------------------------------------
