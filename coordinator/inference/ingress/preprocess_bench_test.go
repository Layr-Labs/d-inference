package ingress

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/inferencefixture"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// benchPreprocess mirrors handleChatCompletions from the prelude through the
// routing-trait derivation: traits for the resolved build (handler, then again
// in the admission preflight), the resolved build's size verdict, and the
// alias-fallback build's traits — the probe the preflight issues only when the
// desired build is saturated, included here so the fallback candidate's cost
// is always measured.
func benchPreprocess(b *testing.B, srv *Controller, body []byte) {
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
	if response.ApplyMetadataDetailsRequest(r, parsed) {
		fb.markDirty()
	}
	shape := introspectRequest(parsed)
	requiresVision := shape.requiresVision()
	hasTools := shape.hasTools
	validatedPolicy, err := toolpolicy.ValidateParsed(parsed, prelude.originalTools)
	if err != nil {
		b.Fatalf("constraint validation: %v", err)
	}
	traits := registry.RequestTraits{
		HasTools:          hasTools,
		ToolChoiceMode:    string(validatedPolicy.Mode),
		ToolChoiceName:    validatedPolicy.Name,
		ParallelToolCalls: validatedPolicy.Parallel,
	}
	buildModel, _, rewrote, ok := srv.resolveRequestedBuild(
		parsed, model, nil, dispatch.RoutePolicy{}, traits)
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
	if rec, err := srv.deps.Store().GetModelRegistryRecord(model); err == nil {
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
	requestedMaxTokens, validOutput := estimateRequestedMaxTokens(parsed)
	if !validOutput || estimatedPromptTokens <= 0 || billingPromptTokens <= 0 || requestedMaxTokens <= 0 {
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
	bodies.traits(inferencefixture.PreviousBuild)
	if err := bodies.sizeError(model); err != nil {
		b.Fatal(err)
	}
	if shape.mediaParts < 0 || len(providerBody) == 0 {
		b.Fatal("unexpected preprocessing state")
	}
}

func BenchmarkChatPreprocessHelpers(b *testing.B) {
	bodies := inferencefixture.RequestBodies()
	srv, _, _ := newBenchController(b)
	registerBuildsProvider(srv, "bench-provider", inferencefixture.DesiredBuild, inferencefixture.PreviousBuild)
	for _, name := range inferencefixture.BodyNames {
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

// BenchmarkRequestIntrospection measures the single-value wrappers the generic
// handler calls individually (they must stay type-level walks, never
// byte scans) against the fused pass and the billing byte count.
func BenchmarkRequestIntrospection(b *testing.B) {
	body := inferencefixture.RequestBodies()["image_3MB"]
	parsed, err := dispatch.DecodeJSONObject(body)
	if err != nil {
		b.Fatal(err)
	}
	for name, fn := range map[string]func(map[string]any) int{
		"detectMediaRequirement": func(p map[string]any) int {
			if detectMediaRequirement(p) {
				return 1
			}
			return 0
		},
		"countMediaParts":             countMediaParts,
		"estimatePromptTokens":        inferencefixture.PromptTokens,
		"estimateBillingPromptTokens": inferencefixture.BillingTokens,
		"introspectRequest":           func(p map[string]any) int { return introspectRequest(p).mediaParts },
	} {
		b.Run(name, func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if fn(parsed) < 0 {
					b.Fatal("negative")
				}
			}
		})
	}
}
