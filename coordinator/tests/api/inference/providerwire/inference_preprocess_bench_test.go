package providerwire_test

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

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/prelude"
	. "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
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
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testkit.ModelHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: model, Version: "v1", R2Prefix: testkit.ModelPrefix(model, "v1"),
		AggregateSHA256: testkit.ModelHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
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
func newBenchServer(tb testing.TB) (*prelude.Parser, *registry.Registry, *memory.MemoryStore) {
	tb.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	seedBenchModel(tb, st, benchDesiredBuild, map[string]any{
		"reasoning_parser": "qwen3",
		"tool_call_parser": "qwen3_coder",
	})
	seedBenchModel(tb, st, benchPreviousBuild, nil)
	reg := registry.New(logger)
	srv := &prelude.Parser{KeyModelAllowed: func(context.Context, string) bool { return true }}
	reg.SetModelAliases(map[string]registry.AliasTarget{
		benchAlias: {Desired: benchDesiredBuild, Previous: benchPreviousBuild},
	})
	return srv, reg, st
}

// benchPreprocess mirrors handleChatCompletions from the prelude through the
// routing-trait derivation: traits for the resolved build (handler, then again
// in the admission preflight), the resolved build's size verdict, and the
// alias-fallback build's traits — the probe the preflight issues only when the
// desired build is saturated, included here so the fallback candidate's cost
// is always measured.
func benchPreprocess(b *testing.B, srv *prelude.Parser, reg *registry.Registry, st store.Store, body []byte) {
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	w := httptest.NewRecorder()
	prelude, ok := srv.Parse(w, r)
	if !ok {
		b.Fatalf("prelude failed: %s", w.Body.String())
	}
	fb := &prelude.Body
	parsed := prelude.Parsed
	model := prelude.Model
	runtimeDefaults := inreq.NewModelRuntimeDefaults(parsed)
	_, reasoningProvided := parsed["reasoning"]

	if inreq.StripProviderRoutingFields(parsed) {
		fb.MarkDirty()
	}
	if inreq.ApplyMetadataDetailsRequest(r, parsed) {
		fb.MarkDirty()
	}
	shape := inreq.IntrospectRequest(parsed)
	hasTools := shape.HasTools
	validatedPolicy, err := inreq.ValidateParsedToolConstraintPolicy(
		inreq.ConstraintView(parsed, prelude.OriginalTools))
	if err != nil {
		b.Fatalf("constraint validation: %v", err)
	}
	traits := registry.RequestTraits{
		HasTools:          hasTools,
		ToolChoiceMode:    string(validatedPolicy.Mode),
		ToolChoiceName:    validatedPolicy.Name,
		ParallelToolCalls: validatedPolicy.Parallel,
	}
	buildModel, rewrote, ok := reg.ResolveModelConstrainedWithTraits(model, nil, "", false, false, traits)
	if !ok {
		b.Fatal("alias did not resolve")
	}
	model = buildModel
	if rewrote {
		parsed["model"] = buildModel
		fb.MarkDirty()
	}
	if inreq.ApplyResolvedModelReasoningPolicy(parsed, model, false, reasoningProvided) {
		fb.MarkDirty()
	}
	maxOutputBound := 8192
	if rec, err := st.GetModelRegistryRecord(model); err == nil {
		if runtimeDefaults.Apply(parsed, rec.RuntimeParameters) {
			fb.MarkDirty()
		}
		if rec.MaxOutputLength > 0 {
			maxOutputBound = rec.MaxOutputLength
		}
	}
	if EnsureMaxTokensBound(parsed, false, maxOutputBound) {
		fb.MarkDirty()
	}
	estimatedPromptTokens := shape.RoutingPromptTokens(parsed)
	billingPromptTokens := shape.BillingPromptTokens(parsed)
	requestedMaxTokens := inreq.EstimateRequestedMaxTokens(parsed)
	if estimatedPromptTokens <= 0 || billingPromptTokens <= 0 || requestedMaxTokens <= 0 {
		b.Fatal("estimates must be positive")
	}

	providerBody, err := fb.Current()
	if err != nil {
		b.Fatal(err)
	}
	bodies := NewMemo(func(candidateModel string) ([]byte, error) {
		return CandidateBody(st, parsed, runtimeDefaults, candidateModel,
			false, reasoningProvided, false)
	}, hasTools)
	bodies.Seed(model, providerBody)
	// handleChatCompletions: routingTraits := routingTraitsForModel(model).
	bodies.Traits(model)
	// runInferenceAdmission: modelTraits(model) for the capacity probe,
	// fallbackTraits → traitsForModel(previous), providerBodyErrorForModel(model).
	bodies.Traits(model)
	bodies.Traits(benchPreviousBuild)
	if err := bodies.SizeError(model); err != nil {
		b.Fatal(err)
	}
	if shape.MediaParts < 0 || len(providerBody) == 0 {
		b.Fatal("unexpected preprocessing state")
	}
}

func BenchmarkChatPreprocessHelpers(b *testing.B) {
	bodies := benchRequestBodies()
	srv, reg, st := newBenchServer(b)
	testkit.RegisterBuildsProvider(reg, "bench-provider", benchDesiredBuild, benchPreviousBuild)
	for _, name := range benchBodyNames {
		body := bodies[name]
		b.Run(name, func(b *testing.B) {
			b.ReportAllocs()
			b.SetBytes(int64(len(body)))
			for i := 0; i < b.N; i++ {
				benchPreprocess(b, srv, reg, st, body)
			}
		})
	}
}
