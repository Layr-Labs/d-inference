package api

// Benchmarks for the consumer inference request preprocessing pipeline: the
// prelude (read → tool-schema normalize → parse), request introspection
// (media/tools/token estimates), tool-constraint validation, alias resolution,
// reasoning/runtime-default/max_tokens rewrites, the provider-bound body
// derivation, and the per-candidate routing-trait sizing.
//
// Two levels:
//
//   - BenchmarkChatPreprocessHelpers drives the helper functions in the same
//     order handleChatCompletions calls them, without HTTP, billing, or
//     dispatch — the precise ns/op, B/op, allocs/op view of the CPU and
//     allocation churn per request shape.
//   - BenchmarkChatCompletionsHTTP drives the real /v1/chat/completions handler
//     through httptest against a fake WebSocket provider, so it includes
//     encryption and transport. Its bytes/allocs are process-wide and the
//     honest end-to-end before/after comparison; its ns/op is noisier.
//
// Bodies: a 2 KB single-turn chat, a 60 KB chat history, that history plus a
// tool set (normalization + constraint validation), and a 3 MB inline-image
// request.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const (
	benchAlias         = "bench-alias"
	benchDesiredBuild  = "bench-build-desired"
	benchPreviousBuild = "bench-build-previous"
)

var benchBodyNames = []string{"small_2KB", "history_60KB", "history_tools_60KB", "image_3MB"}

// benchTurnText is ~1.4 KB of prose carrying the characters the forward
// marshal must handle (quotes, backslashes, newlines, HTML-significant bytes).
var benchTurnText = strings.Repeat(
	`The quick "brown" fox <jumps> over the lazy dog & keeps running.\nIt said: `+
		`"don't stop" — then paused for 3.5 seconds before continuing east. `,
	10)

func benchChatMessage(role, text string) map[string]any {
	return map[string]any{"role": role, "content": text}
}

func benchTools() []any {
	tools := make([]any, 0, 6)
	for i := 0; i < 6; i++ {
		tools = append(tools, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        fmt.Sprintf("lookup_%d", i),
				"description": "Look something up",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						// Missing `type` and a nullable union: both are shapes the
						// coordinator-side normalizer repairs.
						"query":  map[string]any{"description": "search text"},
						"limit":  map[string]any{"type": []any{"integer", "null"}},
						"filter": map[string]any{"type": "string", "enum": []any{"a", "b"}},
					},
					"required": []any{"query"},
				},
			},
		})
	}
	return tools
}

// benchRequestBodies builds the request bodies keyed by benchBodyNames.
func benchRequestBodies() map[string][]byte {
	small := map[string]any{
		"model":  benchAlias,
		"stream": false,
		"messages": []any{
			benchChatMessage("system", "You are a concise assistant."),
			benchChatMessage("user", benchTurnText),
		},
	}
	history := make([]any, 0, 42)
	history = append(history, benchChatMessage("system", "You are a concise assistant."))
	for i := 0; i < 40; i++ {
		role := "user"
		if i%2 == 1 {
			role = "assistant"
		}
		history = append(history, benchChatMessage(role, benchTurnText))
	}
	history = append(history, benchChatMessage("user", "Summarize the conversation."))
	historyBody := map[string]any{"model": benchAlias, "stream": false, "messages": history}
	historyTools := map[string]any{
		"model": benchAlias, "stream": false, "messages": history,
		"tools": benchTools(), "tool_choice": "auto",
	}

	// ~2.25 MB of incompressible bytes → ~3 MB of base64 in a data: URI.
	rnd := rand.New(rand.NewPCG(7, 11))
	raw := make([]byte, 2_250_000)
	for i := 0; i+8 <= len(raw); i += 8 {
		v := rnd.Uint64()
		for j := 0; j < 8; j++ {
			raw[i+j] = byte(v >> (8 * j))
		}
	}
	image := map[string]any{
		"model": benchAlias, "stream": false, "max_tokens": 64,
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "text", "text": "Describe this image."},
			map[string]any{"type": "image_url", "image_url": map[string]any{
				"url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(raw),
			}},
		}}},
	}

	bodies := make(map[string][]byte, 4)
	for name, v := range map[string]any{
		"small_2KB": small, "history_60KB": historyBody,
		"history_tools_60KB": historyTools, "image_3MB": image,
	} {
		b, err := json.Marshal(v)
		if err != nil {
			panic(err)
		}
		bodies[name] = b
	}
	return bodies
}

func seedBenchModel(tb testing.TB, st store.Store, model string, runtimeParameters map[string]any) {
	tb.Helper()
	entry := &store.ModelRegistryEntry{
		ID: model, DisplayName: model, Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 8192, MinRAMGB: 24,
		Capabilities: []string{"chat", "vision"}, Status: "active",
		RuntimeParameters: runtimeParameters,
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: model, Version: "v1", R2Prefix: modelR2Prefix(model, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		tb.Fatal(err)
	}
	if err := st.PromoteModelVersion(model, "v1"); err != nil {
		tb.Fatal(err)
	}
}

// newBenchServer builds a coordinator with the desired/previous builds in the
// registry store (desired carries catalog runtime defaults so the
// runtime-defaults rewrite fires) and the alias pointing at them.
func newBenchServer(tb testing.TB) (*Server, *registry.Registry, *store.MemoryStore) {
	tb.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	seedBenchModel(tb, st, benchDesiredBuild, map[string]any{
		"reasoning_parser": "qwen3",
		"tool_call_parser": "qwen3_coder",
	})
	seedBenchModel(tb, st, benchPreviousBuild, nil)
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour
	srv.SyncModelCatalog()
	reg.SetModelAliases(map[string]registry.AliasTarget{
		benchAlias: {Desired: benchDesiredBuild, Previous: benchPreviousBuild},
	})
	return srv, reg, st
}

// ---------------------------------------------------------------------------
// Helper-level benchmark
// ---------------------------------------------------------------------------

// benchPreprocess mirrors handleChatCompletions from the prelude through the
// routing-trait derivation: traits for the resolved build (handler, then again
// in the admission preflight), the resolved build's size verdict, and the
// alias-fallback build's traits — the probe the preflight issues only when the
// desired build is saturated, included here so the fallback candidate's cost
// is always measured.
func benchPreprocess(b *testing.B, srv *Server, body []byte) {
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	w := httptest.NewRecorder()
	prelude, ok := srv.parseInferencePrelude(w, r)
	if !ok {
		b.Fatalf("prelude failed: %s", w.Body.String())
	}
	fb := &prelude.body
	parsed := prelude.parsed
	model := prelude.model
	runtimeDefaults := newModelRuntimeDefaults(parsed)
	_, reasoningProvided := parsed["reasoning"]

	if stripProviderRoutingFields(parsed) {
		fb.markDirty()
	}
	if applyMetadataDetailsRequest(r, parsed) {
		fb.markDirty()
	}
	shape := introspectRequest(parsed)
	requiresVision := shape.requiresVision()
	hasTools := shape.hasTools
	validatedPolicy, err := validateParsedToolConstraintPolicy(
		constraintView(parsed, prelude.originalTools))
	if err != nil {
		b.Fatalf("constraint validation: %v", err)
	}
	traits := registry.RequestTraits{
		HasTools:          hasTools,
		ToolChoiceMode:    string(validatedPolicy.mode),
		ToolChoiceName:    validatedPolicy.name,
		ParallelToolCalls: validatedPolicy.parallel,
	}
	buildModel, _, rewrote, ok := srv.resolveRequestedBuild(
		parsed, model, nil, selfRoutePolicy{}, traits)
	if !ok {
		b.Fatal("alias did not resolve")
	}
	model = buildModel
	if rewrote {
		fb.markDirty()
	}
	if applyResolvedModelReasoningPolicy(parsed, model, false, reasoningProvided) {
		fb.markDirty()
	}
	maxOutputBound := defaultMaxOutputTokens
	if rec, err := srv.store.GetModelRegistryRecord(model); err == nil {
		if runtimeDefaults.apply(parsed, rec.RuntimeParameters) {
			fb.markDirty()
		}
		if rec.MaxOutputLength > 0 {
			maxOutputBound = rec.MaxOutputLength
		}
	}
	if ensureMaxTokensBound(parsed, false, maxOutputBound) {
		fb.markDirty()
	}
	estimatedPromptTokens := shape.routingPromptTokens(parsed)
	billingPromptTokens := shape.billingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	if estimatedPromptTokens <= 0 || billingPromptTokens <= 0 || requestedMaxTokens <= 0 {
		b.Fatal("estimates must be positive")
	}

	providerBody, err := fb.current()
	if err != nil {
		b.Fatal(err)
	}
	bodies := newProviderBodyMemo(func(candidateModel string) ([]byte, error) {
		return srv.candidateProviderBody(parsed, runtimeDefaults, candidateModel,
			false, reasoningProvided, false)
	}, hasTools, requiresVision)
	bodies.seed(model, providerBody)
	// handleChatCompletions: routingTraits := routingTraitsForModel(model).
	bodies.traits(model)
	// runInferenceAdmission: modelTraits(model) for the capacity probe,
	// fallbackTraits → traitsForModel(previous), providerBodyErrorForModel(model).
	bodies.traits(model)
	bodies.traits(benchPreviousBuild)
	if err := bodies.sizeError(model); err != nil {
		b.Fatal(err)
	}
	if shape.mediaParts < 0 || len(providerBody) == 0 {
		b.Fatal("unexpected preprocessing state")
	}
}

func BenchmarkChatPreprocessHelpers(b *testing.B) {
	bodies := benchRequestBodies()
	srv, _, _ := newBenchServer(b)
	registerBuildsProvider(srv, "bench-provider", benchDesiredBuild, benchPreviousBuild)
	for _, name := range benchBodyNames {
		body := bodies[name]
		b.Run(name, func(b *testing.B) {
			b.ReportAllocs()
			b.SetBytes(int64(len(body)))
			for i := 0; i < b.N; i++ {
				benchPreprocess(b, srv, body)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// HTTP-level benchmark
// ---------------------------------------------------------------------------

type benchEnv struct {
	ts     *httptest.Server
	conn   *websocket.Conn
	cancel context.CancelFunc
	client *http.Client
}

func (e *benchEnv) close() {
	e.cancel()
	_ = e.conn.Close(websocket.StatusNormalClosure, "bench done")
	e.ts.Close()
}

// newBenchEnv starts the coordinator and one trusted, vision-capable fake
// provider that answers challenges and serves every dispatch with a role
// chunk, one content chunk, and a completion.
func newBenchEnv(b *testing.B) *benchEnv {
	b.Helper()
	srv, reg, _ := newBenchServer(b)
	ts := httptest.NewServer(srv.Handler())
	ctx, cancel := context.WithCancel(context.Background())

	pubKey := testPublicKeyB64()
	value, ok := testProviderKeys.Load(pubKey)
	if !ok {
		b.Fatalf("missing cached provider keypair for %q", pubKey)
	}
	keypair := value.(testProviderKeyPair)

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		b.Fatalf("websocket dial: %v", err)
	}
	conn.SetReadLimit(64 << 20)
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64,
		},
		Models: []protocol.ModelInfo{
			{ID: benchDesiredBuild, ModelType: "chat", Quantization: "4bit", IsVision: true},
			{ID: benchPreviousBuild, ModelType: "chat", Quantization: "4bit", IsVision: true},
		},
		Backend:                 "mlx-swift",
		Version:                 "0.8.0",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		DecodeTPS:               100,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		b.Fatalf("write register: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for len(reg.ProviderIDs()) == 0 {
		if time.Now().After(deadline) {
			b.Fatal("provider never registered")
		}
		time.Sleep(10 * time.Millisecond)
	}
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}
	go benchProviderLoop(ctx, conn, pubKey, keypair)
	return &benchEnv{ts: ts, conn: conn, cancel: cancel, client: ts.Client()}
}

func benchEncryptedChunk(req protocol.InferenceRequestMessage, keypair testProviderKeyPair, sse string) ([]byte, error) {
	if req.EncryptedBody == nil {
		return nil, fmt.Errorf("inference request %s missing encrypted body", req.RequestID)
	}
	coordinatorPub, err := e2e.ParsePublicKey(req.EncryptedBody.EphemeralPublicKey)
	if err != nil {
		return nil, err
	}
	payload, err := e2e.Encrypt([]byte(sse), coordinatorPub, &e2e.SessionKeys{
		PublicKey: keypair.public, PrivateKey: keypair.private,
	})
	if err != nil {
		return nil, err
	}
	return json.Marshal(protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: req.RequestID,
		EncryptedData: &protocol.EncryptedPayload{
			EphemeralPublicKey: payload.EphemeralPublicKey,
			Ciphertext:         payload.Ciphertext,
		},
	})
}

func benchProviderLoop(ctx context.Context, conn *websocket.Conn, pubKey string, keypair testProviderKeyPair) {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(data, &envelope) != nil {
			continue
		}
		switch envelope.Type {
		case protocol.TypeAttestationChallenge:
			if err := conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey)); err != nil {
				return
			}
		case protocol.TypeInferenceRequest:
			var req protocol.InferenceRequestMessage
			if json.Unmarshal(data, &req) != nil {
				continue
			}
			// The body is deliberately NOT decrypted: the benchmark measures the
			// coordinator, and a 3 MB NaCl open on the fake provider would only
			// add provider-side noise to the process-wide allocation numbers.
			for _, sse := range []string{
				roleOnlyChunkSSE(benchDesiredBuild),
				contentChunkSSE(benchDesiredBuild, "bench"),
			} {
				frame, err := benchEncryptedChunk(req, keypair, sse)
				if err != nil {
					return
				}
				if err := conn.Write(ctx, websocket.MessageText, frame); err != nil {
					return
				}
			}
			complete, _ := json.Marshal(protocol.InferenceCompleteMessage{
				Type: protocol.TypeInferenceComplete, RequestID: req.RequestID,
				Usage: protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
			})
			if err := conn.Write(ctx, websocket.MessageText, complete); err != nil {
				return
			}
		}
	}
}

func (e *benchEnv) post(body []byte) (int, error) {
	req, err := http.NewRequest(http.MethodPost, e.ts.URL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := e.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, fmt.Errorf("status %d: %s", resp.StatusCode, msg)
	}
	_, err = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode, err
}

func BenchmarkChatCompletionsHTTP(b *testing.B) {
	bodies := benchRequestBodies()
	for _, name := range benchBodyNames {
		body := bodies[name]
		b.Run(name, func(b *testing.B) {
			env := newBenchEnv(b)
			defer env.close()
			// Warm the path once (provider registration, alias catalog, HTTP
			// keep-alive) before timing.
			if _, err := env.post(body); err != nil {
				b.Fatal(err)
			}
			b.ReportAllocs()
			b.SetBytes(int64(len(body)))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := env.post(body); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
