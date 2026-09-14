package toolpolicy

import (
	"errors"
	"fmt"
	"testing"
)

// autoStandardSchemaCorpus is the set of JSON-Schema constructs #561 started
// rejecting for every model. They are all emitted by mainstream SDKs (pydantic
// and zod hoist definitions into `$defs`/`$ref`; unions become anyOf/oneOf),
// and they are all decidable by the post-generation validator that auto and
// none actually use — so the pre-flight must forward them untouched. The value
// is the property schema placed under a single declared tool; constrained is
// the kind the grammar-compiled modes still reject it with.
var autoStandardSchemaCorpus = map[string]struct {
	property    string
	constrained ErrorKind
}{
	"anyOf string|object": {`{"anyOf":[{"type":"string"},
		{"type":"object","properties":{"source":{"type":"string"}}}]}`,
		UnsupportedSchema},
	"oneOf string|integer": {`{"oneOf":[{"type":"string"},{"type":"integer"}]}`,
		UnsupportedSchema},
	"patternProperties": {`{"type":"object","patternProperties":{"^[A-Z_]+$":{"type":"string"}}}`,
		UnsupportedSchema},
	"pattern": {`{"type":"string","pattern":"^[a-f0-9]{8}$"}`,
		UnsupportedSchema},
	"if/then": {`{"type":"object","if":{"required":["a"]},"then":{"required":["b"]}}`,
		UnsupportedSchema},
	"dependentRequired": {`{"type":"object","dependentRequired":{"credit_card":["billing_address"]}}`,
		UnsupportedSchema},
	"propertyNames": {`{"type":"object","propertyNames":{"pattern":"^[a-z]+$"}}`,
		UnsupportedSchema},
	"unevaluatedProperties": {`{"type":"object","unevaluatedProperties":false}`,
		UnsupportedSchema},
	"multi-type": {`{"type":["string","integer"]}`,
		UnsupportedSchema},
	// A typeless mixed enum reaches the constrained compiler's finite-value
	// check rather than its keyword allowlist, so it fails as a malformed
	// request (400) instead of an uncompilable one (422).
	"typeless mixed enum": {`{"enum":["a",1]}`, InvalidRequest},
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
		reject := func(name string, body []byte, want ErrorKind) {
			t.Helper()
			_, err := validateToolConstraintRequest(body)
			var typed *ValidationError
			if !errors.As(err, &typed) || typed.Kind != want {
				t.Errorf("%s in constrained mode: %T %v, want error kind %d",
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
			UnsupportedSchema)
	})

	// The one rejection that survives in the non-grammar modes: the caller
	// cannot plant the coordinator's own normalization marker. Validation runs
	// on the pre-normalization body, so any occurrence is forged.
	t.Run("forged reserved metadata still rejected", func(t *testing.T) {
		// The multi-concrete `type` array beside an author combinator is the
		// collapse-only normalization path — the guard must still descend the
		// author's anyOf and catch a marker planted inside it.
		for name, property := range map[string]string{
			"bare marker": `{"type":"string","x-darkbloom-original-boolean-schema":true}`,
			"marker inside author anyOf on a type-array node": `{"type":["string","object"],
				"anyOf":[{"type":"string","x-darkbloom-original-boolean-schema":true}]}`,
		} {
			for _, choice := range []string{"auto", "none"} {
				body := autoStandardSchemaBody("gpt-oss-20b", choice, property)
				_, err := validateToolConstraintRequest([]byte(body))
				var typed *ValidationError
				if !errors.As(err, &typed) || typed.Kind != InvalidRequest {
					t.Errorf("%s/%s accepted forged reserved metadata: %T %v",
						choice, name, err, err)
				}
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
			if mode != None {
				t.Fatalf("%s: mode = %q, want none", name, mode)
			}
			if mode.RequiresInferenceConstraint() {
				t.Errorf("%s: none demanded an inference-enforcing provider", name)
			}
		}
	})
}
