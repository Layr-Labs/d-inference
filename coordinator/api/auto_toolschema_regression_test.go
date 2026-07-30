package api

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// autoStandardSchemaCorpus is the set of JSON-Schema constructs #561 started
// rejecting for every model. They are all emitted by mainstream SDKs (pydantic
// and zod hoist definitions into `$defs`/`$ref`; unions become anyOf/oneOf),
// and they are all decidable by the post-generation validator that auto and
// none actually use — so the pre-flight must forward them untouched. The value
// is the property schema placed under a single declared tool; constrained is
// the status the grammar-compiled modes still reject it with.
var autoStandardSchemaCorpus = map[string]struct {
	property    string
	constrained int
}{
	"anyOf string|object": {`{"anyOf":[{"type":"string"},
		{"type":"object","properties":{"source":{"type":"string"}}}]}`,
		http.StatusUnprocessableEntity},
	"oneOf string|integer": {`{"oneOf":[{"type":"string"},{"type":"integer"}]}`,
		http.StatusUnprocessableEntity},
	"patternProperties": {`{"type":"object","patternProperties":{"^[A-Z_]+$":{"type":"string"}}}`,
		http.StatusUnprocessableEntity},
	"pattern": {`{"type":"string","pattern":"^[a-f0-9]{8}$"}`,
		http.StatusUnprocessableEntity},
	"if/then": {`{"type":"object","if":{"required":["a"]},"then":{"required":["b"]}}`,
		http.StatusUnprocessableEntity},
	"dependentRequired": {`{"type":"object","dependentRequired":{"credit_card":["billing_address"]}}`,
		http.StatusUnprocessableEntity},
	"propertyNames": {`{"type":"object","propertyNames":{"pattern":"^[a-z]+$"}}`,
		http.StatusUnprocessableEntity},
	"unevaluatedProperties": {`{"type":"object","unevaluatedProperties":false}`,
		http.StatusUnprocessableEntity},
	"multi-type": {`{"type":["string","integer"]}`,
		http.StatusUnprocessableEntity},
	// A typeless mixed enum reaches the constrained compiler's finite-value
	// check rather than its keyword allowlist, so it fails as a malformed
	// request (400) instead of an uncompilable one (422).
	"typeless mixed enum": {`{"enum":["a",1]}`, http.StatusBadRequest},
}

// autoStandardSchemaBody wraps a property schema in a full chat-completions
// request for the given tool_choice. `$defs`/`$ref` needs a sibling on the
// parameters root, so it is spelled separately below.
func autoStandardSchemaBody(model, choice, property string) string {
	return fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"x"}],
		"tool_choice":%q,
		"tools":[{"type":"function","function":{"name":"set_config_value","parameters":
		{"type":"object","properties":{"value":%s},"required":["value"]}}}]}`,
		model, choice, property)
}

const autoRefDefsBody = `{"model":%q,"messages":[{"role":"user","content":"x"}],
	"tool_choice":%q,
	"tools":[{"type":"function","function":{"name":"f","parameters":
	{"type":"object","$defs":{"P":{"type":"string"}},
	"properties":{"p":{"$ref":"#/$defs/P"}}}}}]}`

// #561 regression. `auto` compiles no inference grammar — ToolConstraintFactory
// returns nil for it and the provider validates emitted calls against the full
// JSON Schema afterwards. The coordinator therefore has no grammar-feasibility
// question to answer at admission time, and must forward standard JSON Schema
// for EVERY model. Only the genuinely grammar-compiled modes fail closed.
func TestAutoToolChoiceForwardsStandardJSONSchema(t *testing.T) {
	// Model-blind: the pre-flight never saw a model, so a Gemma-class name must
	// not be what makes a schema legal.
	models := []string{"gpt-oss-20b", "gemma-4-26b", "totally-made-up"}

	t.Run("accepted under auto", func(t *testing.T) {
		for name, schema := range autoStandardSchemaCorpus {
			for _, model := range models {
				body := autoStandardSchemaBody(model, "auto", schema.property)
				if _, err := validateToolConstraintRequest([]byte(body)); err != nil {
					t.Errorf("%s rejected for model %q: %v", name, model, err)
				}
			}
		}
		for _, model := range models {
			body := fmt.Sprintf(autoRefDefsBody, model, "auto")
			if _, err := validateToolConstraintRequest([]byte(body)); err != nil {
				t.Errorf("$defs/$ref rejected for model %q: %v", model, err)
			}
		}
	})

	// The constrained modes DO compile a grammar, so their allowlist stays
	// fail-closed on exactly these constructs. That asymmetry is the point.
	t.Run("still rejected under required", func(t *testing.T) {
		reject := func(name string, body []byte, want int) {
			t.Helper()
			_, err := validateToolConstraintRequest(body)
			var typed *toolConstraintRequestError
			if !errors.As(err, &typed) || typed.status != want {
				t.Errorf("%s in constrained mode: %T %v, want status %d",
					name, err, err, want)
			}
		}
		for name, schema := range autoStandardSchemaCorpus {
			reject(name,
				[]byte(autoStandardSchemaBody("gpt-oss-20b", "required", schema.property)),
				schema.constrained)
		}
		reject("$defs/$ref",
			[]byte(fmt.Sprintf(autoRefDefsBody, "gpt-oss-20b", "required")),
			http.StatusUnprocessableEntity)
	})

	// The one rejection that survives in the non-grammar modes: the caller
	// cannot plant the coordinator's own normalization marker. Validation runs
	// on the pre-normalization body, so any occurrence is forged.
	t.Run("forged reserved metadata still rejected", func(t *testing.T) {
		for _, choice := range []string{"auto", "none"} {
			body := autoStandardSchemaBody("gpt-oss-20b", choice,
				`{"type":"string","x-darkbloom-original-boolean-schema":true}`)
			_, err := validateToolConstraintRequest([]byte(body))
			var typed *toolConstraintRequestError
			if !errors.As(err, &typed) || typed.status != http.StatusBadRequest {
				t.Errorf("%s accepted forged reserved metadata: %T %v", choice, err, err)
			}
		}
	})

	// `none` is honored by hiding tools from the prompt and rejecting any call
	// the model emits anyway — no sampler grammar, so no Gemma-only fence.
	t.Run("none needs no grammar", func(t *testing.T) {
		bodies := map[string]string{
			"with tools": `{"model":"gpt-oss-20b","messages":[{"role":"user","content":"x"}],
				"tool_choice":"none",
				"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}]}`,
			"without tools": `{"model":"gpt-oss-20b",
				"messages":[{"role":"user","content":"x"}],"tool_choice":"none"}`,
		}
		for name, body := range bodies {
			mode, err := validateToolConstraintRequest([]byte(body))
			if err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			if mode != toolChoiceNone {
				t.Fatalf("%s: mode = %q, want none", name, mode)
			}
			if mode.requiresGrammar() {
				t.Errorf("%s: none demanded an inference-enforcing provider", name)
			}
		}
	})
}

// End-to-end through the real HTTP handler with a non-Gemma model that has no
// constraint-capable provider (the production gpt-oss-20b situation). The union
// and $ref shapes must clear admission and be answered by the ROUTING
// capability gate, never by a 422 schema verdict the auto path never needed.
func TestAutoToolSchemaReachesRoutingOverHTTP(t *testing.T) {
	srv, _ := testServer(t)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "gpt-oss-20b"}})

	bodies := map[string]string{
		"anyOf union": autoStandardSchemaBody("gpt-oss-20b", "auto",
			autoStandardSchemaCorpus["anyOf string|object"].property),
		"$defs/$ref": fmt.Sprintf(autoRefDefsBody, "gpt-oss-20b", "auto"),
	}
	for name, body := range bodies {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(
				http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			request.Header.Set("Authorization", "Bearer test-key")
			response := httptest.NewRecorder()
			srv.Handler().ServeHTTP(response, request)
			if response.Code != http.StatusServiceUnavailable ||
				!strings.Contains(response.Body.String(), "supports tool calls") {
				t.Fatalf("auto request did not reach the routing gate: %d %s",
					response.Code, response.Body.String())
			}
		})
	}
}

// The capability verdict has to tell a client whether retrying can ever help.
// "This model is served but nobody enforces tool_choice" is permanent; only a
// model the fleet does not serve at all is a retryable capacity condition. And
// `none`, which needs no enforcement, must clear both gates.
func TestToolConstraintCapabilityErrorSeparatesPermanentFromTransient(t *testing.T) {
	const model = "gpt-oss-20b"
	failFast := func(t *testing.T, hasTools, requiresConstraint, withProvider bool) *httptest.ResponseRecorder {
		t.Helper()
		srv, _ := testServer(t)
		srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model}})
		if withProvider {
			// Above the tools floor but advertising no tool-constraint
			// protocol: the fleet serves the model, nobody enforces on it.
			provider := registerBuildsProvider(srv, "serving-provider", model)
			provider.Mu().Lock()
			provider.Version = "0.6.5"
			provider.Mu().Unlock()
		}
		response := httptest.NewRecorder()
		handled := srv.visionToolsFailFast(
			response, model, model, false, hasTools, requiresConstraint,
			false, selfRoutePolicy{}, nil)
		if requiresConstraint && !handled {
			t.Fatal("incapable constrained request was allowed into the queue")
		}
		if !requiresConstraint && handled {
			t.Fatalf("unconstrained request was blocked: %d %s",
				response.Code, response.Body.String())
		}
		return response
	}

	served := failFast(t, true, true, true)
	if served.Code != http.StatusBadRequest ||
		!strings.Contains(served.Body.String(),
			"inference-enforced tool_choice (required/named) is not supported") {
		t.Fatalf("permanent incapability reported as capacity: %d %s",
			served.Code, served.Body.String())
	}

	absent := failFast(t, false, true, false)
	if absent.Code != http.StatusServiceUnavailable ||
		!strings.Contains(absent.Body.String(),
			"advertises inference-time tool_choice enforcement") {
		t.Fatalf("absent model lost its retryable capacity error: %d %s",
			absent.Code, absent.Body.String())
	}

	// tool_choice "none" derives requiresToolConstraint=false, so a model with
	// no enforcing provider at all still serves it.
	mode, err := validateToolConstraintRequest([]byte(
		`{"model":"gpt-oss-20b","messages":[{"role":"user","content":"x"}],"tool_choice":"none"}`))
	if err != nil {
		t.Fatal(err)
	}
	failFast(t, false, mode.requiresGrammar(), false)
}
