package api

import (
	"bytes"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// runChatRewrites replays handleChatCompletions' rewrites on a request body up
// to the single serialization point and returns the provider body the handler
// would seal for the resolved build, plus the state candidateProviderBody
// needs to rebuild it.
func runChatRewrites(t *testing.T, srv *Server, body string, service bool) (
	providerBody []byte, parsed map[string]any, defaults modelRuntimeDefaults,
	model string, reasoningProvided, isResponsesAPI, serialized bool,
) {
	t.Helper()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader([]byte(body)))
	w := httptest.NewRecorder()
	prelude, ok := srv.parseInferencePrelude(w, r)
	if !ok {
		t.Fatalf("prelude failed: %s", w.Body.String())
	}
	fb := &prelude.body
	parsed = prelude.parsed
	defaults = newModelRuntimeDefaults(parsed)
	_, reasoningProvided = parsed["reasoning"]
	messages, _ := parsed["messages"].([]any)
	isResponsesAPI = parsed["input"] != nil && len(messages) == 0
	if stripProviderRoutingFields(parsed) {
		fb.markDirty()
	}
	if applyMetadataDetailsRequest(r, parsed) {
		fb.markDirty()
	}
	shape := introspectRequest(parsed)
	buildModel, _, rewrote, ok := srv.resolveRequestedBuild(
		parsed, prelude.model, nil, selfRoutePolicy{}, registry.RequestTraits{HasTools: shape.hasTools})
	if !ok {
		t.Fatalf("model %q did not resolve", prelude.model)
	}
	model = buildModel
	if rewrote {
		fb.markDirty()
	}
	if applyResolvedModelReasoningPolicy(parsed, model, service, reasoningProvided) {
		fb.markDirty()
	}
	maxOutputBound := defaultMaxOutputTokens
	if rec, err := srv.store.GetModelRegistryRecord(model); err == nil {
		if defaults.apply(parsed, rec.RuntimeParameters) {
			fb.markDirty()
		}
		if rec.MaxOutputLength > 0 {
			maxOutputBound = rec.MaxOutputLength
		}
	}
	if ensureMaxTokensBound(parsed, isResponsesAPI, maxOutputBound) {
		fb.markDirty()
	}
	rawBody, err := fb.current()
	if err != nil {
		t.Fatal(err)
	}
	providerBody = rawBody
	if isResponsesAPI {
		if providerBody, err = promptcontract.LowerProviderBody(promptcontract.EndpointResponses, rawBody); err != nil {
			t.Fatal(err)
		}
	}
	return providerBody, parsed, defaults, model, reasoningProvided, isResponsesAPI, fb.serialized
}

// Seeding the memo with the handler's own serialization is only valid if a
// fresh candidateProviderBody for the resolved build produces the same bytes.
// Every rewrite class must hold that invariant, including a request whose
// only added field is the coordinator-owned template date.
func TestProviderBodyMemoSeedMatchesFreshBuild(t *testing.T) {
	srv, _, _ := newBenchServer(t)
	registerBuildsProvider(srv, "memo-provider", benchDesiredBuild, benchPreviousBuild)
	registerBuildsProvider(srv, "memo-qwen-provider", serviceReasoningOptInModel)

	tests := []struct {
		name    string
		body    string
		service bool
	}{
		{"alias + runtime defaults + injected max_tokens", `{"model":"` + benchAlias + `","messages":[{"role":"user","content":"hi"}]}`, false},
		{"raw build, explicit max_completion_tokens alias field", `{"model":"` + benchDesiredBuild + `","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":7}`, false},
		{"stop string normalized", `{"model":"` + benchDesiredBuild + `","messages":[{"role":"user","content":"hi"}],"stop":"END","max_tokens":3}`, false},
		{"service reasoning injected", `{"model":"` + serviceReasoningOptInModel + `","messages":[{"role":"user","content":"hi"}],"max_tokens":3}`, true},
		{"service reasoning explicit", `{"model":"` + serviceReasoningOptInModel + `","messages":[{"role":"user","content":"hi"}],"reasoning":{"enabled":true},"max_tokens":3}`, true},
		{"non-service qwen date only", `{"model":"` + serviceReasoningOptInModel + `", "messages":[{"role":"user","content":"hi"}], "max_tokens":3}`, false},
		{"caller-provided parser default kept", `{"model":"` + benchAlias + `","messages":[{"role":"user","content":"hi"}],"tool_call_parser":"mine","max_tokens":3}`, false},
		{"private routing field stripped", `{"model":"` + benchAlias + `","messages":[{"role":"user","content":"hi"}],"provider_serial":"C02XYZ","max_tokens":3}`, false},
		{"responses lowered", `{"model":"` + benchAlias + `","input":"hello","max_output_tokens":5}`, false},
		{"responses date only", `{"model":"` + serviceReasoningOptInModel + `","input":"hello","max_output_tokens":5}`, false},
		{"tools normalized", `{"model":"` + benchAlias + `","messages":[{"role":"user","content":"hi"}],"max_tokens":3,"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"description":"x"}}}}}]}`, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			providerBody, parsed, defaults, model, reasoningProvided, isResponsesAPI, serialized :=
				runChatRewrites(t, srv, test.body, test.service)
			if !serialized {
				t.Fatal("request date was not included in coordinator serialization")
			}
			fresh, err := srv.candidateProviderBody(parsed, defaults, model, test.service, reasoningProvided, isResponsesAPI)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(fresh, providerBody) {
				t.Fatalf("fresh candidate body diverged from the handler's serialization:\n got %s\nwant %s", fresh, providerBody)
			}
			// A fallback candidate rebuilt after the handler's own rewrites must
			// equal the same candidate built from the pristine map — the invariant
			// the admission preflight relies on when it probes Previous before the
			// alias fallback mutates parsed.
			if !isResponsesAPI && model == benchDesiredBuild {
				before, err := srv.candidateProviderBody(parsed, defaults, benchPreviousBuild, test.service, reasoningProvided, false)
				if err != nil {
					t.Fatal(err)
				}
				// Simulate the fallback the handler applies: model rewritten, defaults
				// reconciled for the new build, reasoning policy re-applied, then a
				// fresh serialization — which the memo would be seeded with.
				parsed["model"] = benchPreviousBuild
				if rec, err := srv.store.GetModelRegistryRecord(benchPreviousBuild); err == nil {
					defaults.apply(parsed, rec.RuntimeParameters)
				} else {
					defaults.apply(parsed, nil)
				}
				applyResolvedModelReasoningPolicy(parsed, benchPreviousBuild, test.service, reasoningProvided)
				after, err := marshalForwardBody(parsed)
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(before, after) {
					t.Fatalf("fallback candidate differs from the post-fallback serialization:\n got %s\nwant %s", before, after)
				}
			}
		})
	}
}

func TestProviderBodyMemoBuildsOncePerModel(t *testing.T) {
	builds := map[string]int{}
	memo := newProviderBodyMemo(func(model string) ([]byte, error) {
		builds[model]++
		if model == "broken" {
			return nil, errors.New("cannot build")
		}
		return []byte(`{"model":"` + model + `"}`), nil
	}, true, false)

	memo.seed("seeded", []byte(`{"model":"seeded","seeded":true}`))
	if body, err := memo.body("seeded"); err != nil || !bytes.Contains(body, []byte(`"seeded":true`)) {
		t.Fatalf("seeded body = %s, %v", body, err)
	}
	for i := 0; i < 3; i++ {
		if _, ok := memo.traits("seeded"); !ok {
			t.Fatal("seeded traits unavailable")
		}
		if err := memo.sizeError("seeded"); err != nil {
			t.Fatal(err)
		}
		if _, ok := memo.traits("fresh"); !ok {
			t.Fatal("fresh traits unavailable")
		}
		if _, err := memo.body("fresh"); err != nil {
			t.Fatal(err)
		}
	}
	if builds["seeded"] != 0 || builds["fresh"] != 1 {
		t.Fatalf("builds = %v, want seeded:0 fresh:1", builds)
	}
	traits, _ := memo.traits("fresh")
	if !traits.HasTools {
		t.Fatalf("traits lost HasTools: %+v", traits)
	}

	// A build failure yields no traits and no size error (a build failure is
	// not a size verdict), and is not retried.
	if _, ok := memo.traits("broken"); ok {
		t.Fatal("broken candidate reported traits")
	}
	if err := memo.sizeError("broken"); err != nil {
		t.Fatalf("broken candidate reported size error %v", err)
	}
	memo.sizeError("broken")
	if builds["broken"] != 1 {
		t.Fatalf("broken rebuilt %d times", builds["broken"])
	}

	// reset forgets everything, including seeds.
	memo.reset()
	if _, err := memo.body("seeded"); err != nil {
		t.Fatal(err)
	}
	if builds["seeded"] != 1 {
		t.Fatalf("seeded not rebuilt after reset: %v", builds)
	}
}
