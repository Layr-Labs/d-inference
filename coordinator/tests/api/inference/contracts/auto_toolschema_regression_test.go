package inference_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
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

// End-to-end through the real HTTP handler with a non-Gemma model that has no
// constraint-capable provider (the production gpt-oss-20b situation). The union
// and $ref shapes must clear admission and be answered by the ROUTING
// capability gate, never by a 422 schema verdict the auto path never needed.
func TestAutoToolSchemaReachesRoutingOverHTTP(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	srv := fixture.Server
	fixture.Registry.SetModelCatalog([]registry.CatalogEntry{{ID: "gpt-oss-20b"}})

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
