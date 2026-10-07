package request_test

import (
	"bytes"
	"reflect"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/request"

	jsonvalue "github.com/eigeninference/d-inference/coordinator/internal/inference/jsonvalue"

	toolpolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/toolpolicy"
)

// toolNormalizationParityBodies cover every schema home and repair class the
// normalizer handles, plus the gates it must respect. Each is paired with a
// message history so the whole-body round trip (not just the tools) is
// compared.
var toolNormalizationParityBodies = map[string]string{
	"chat missing type": `{"model":"m","messages":[{"role":"user","content":"x <y> & z"}],
		"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"description":"text"}}}}}]}`,
	"chat nullable union": `{"model":"m","messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"n":{"type":["integer","null"]}}}}}]}`,
	"chat boolean positional": `{"model":"m","messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"any":true,"none":{}}}}}]}`,
	"responses flat shape": `{"model":"m","input":"hi","tools":[{"type":"function","name":"f","parameters":{"type":"object","properties":{"q":{"description":"text"}}}}]}`,
	"anthropic input_schema": `{"model":"m","messages":[{"role":"user","content":"x"}],
		"tools":[{"name":"f","input_schema":{"type":"object","properties":{"q":{"enum":["a","b"]}}}}]}`,
	"already normalized": `{"model":"m","messages":[{"role":"user","content":"x"}],
		"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"type":"string"}}}}}]}`,
	"no tools": `{"model":"m","messages":[{"role":"user","content":"the word \"tools\" in text"}]}`,
	// The bytes path gates on the literal `"tools"` bytes: an escaped spelling of
	// the key is forwarded verbatim (schemas unrepaired), and so must this path.
	"escaped tools key": `{"model":"m","messages":[{"role":"user","content":"x"}],"to\u006fls":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"description":"text"}}}}}]}`,
	"tools not array":   `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":{"type":"function"}}`,
	"scalar tool":       `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":["nope",1,null]}`,
	"numbers preserved": `{"model":"m","messages":[{"role":"user","content":"x"}],"metadata":{"exact":9007199254740993,"decimal":0.10000000000000001},
		"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"description":"text","default":1e400}}}}}]}`,
	"invalid utf8 in messages and keys": "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"bad \xff\xfe bytes\",\"na\xffme\":\"v\xe2\x82\"}]," +
		`"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"description":"text"}}}}}]}`,
}

func decodeForParity(t *testing.T, body string) map[string]any {
	t.Helper()
	parsed, err := production.DecodeInferenceJSONObject([]byte(body))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	return parsed
}

func TestNormalizeParsedToolSchemasRespectsSizeGate(t *testing.T) {
	body := toolNormalizationParityBodies["chat missing type"]
	parsed := decodeForParity(t, body)
	before := jsonvalue.Clone(parsed)
	padded := append([]byte(body), bytes.Repeat([]byte(" "), fixtureMaxToolNormalizationBytes)...)
	if _, changed := production.NormalizeParsedToolSchemas(parsed, padded); changed {
		t.Fatal("oversize body was normalized")
	}
	if !reflect.DeepEqual(parsed, before) {
		t.Fatal("oversize body was mutated")
	}
	// The bytes path skips the same bodies.
	if got := production.NormalizeToolSchemas(padded); !bytes.Equal(got, padded) {
		t.Fatal("bytes path normalized an oversize body")
	}
}

// The chat prelude validates constraints on the PRE-normalization tools: a
// client-forged marker is refused, while the marker the normalizer itself
// stamps (visible only in the repaired copy) never reaches the validator.
func TestParsedConstraintValidationSeesPreNormalizationTools(t *testing.T) {
	body := `{"model":"m","messages":[{"role":"user","content":"x"}],"tool_choice":"auto",
		"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"any":true}}}}]}`
	parsed := decodeForParity(t, body)
	originalTools, changed := production.NormalizeParsedToolSchemas(parsed, []byte(body))
	if !changed || originalTools == nil {
		t.Fatal("boolean positional schema was not repaired")
	}
	// The repaired copy now carries the reserved marker …
	repaired, _ := production.MarshalForwardBody(parsed["tools"])
	if !bytes.Contains(repaired, []byte(toolpolicy.OriginalBooleanSchemaKey)) {
		t.Fatalf("repaired tools lack the marker: %s", repaired)
	}
	// … so validating the repaired view would wrongly reject the request …
	if _, err := production.ValidateParsedToolConstraintPolicy(parsed); err == nil {
		t.Fatal("repaired view accepted (marker not detected); test premise broken")
	}
	// … while the original view (what the handler validates) accepts it.
	view := production.ConstraintView(parsed, originalTools)
	if _, err := production.ValidateParsedToolConstraintPolicy(view); err != nil {
		t.Fatalf("original view rejected: %v", err)
	}
	// And a genuinely forged marker in the caller's body still fails closed.
	forged := strings.Replace(body, `"any":true`, `"any":{"type":"string","`+toolpolicy.OriginalBooleanSchemaKey+`":true}`, 1)
	forgedParsed := decodeForParity(t, forged)
	forgedTools, forgedChanged := production.NormalizeParsedToolSchemas(forgedParsed, []byte(forged))
	if _, err := production.ValidateParsedToolConstraintPolicy(production.ConstraintView(forgedParsed, forgedTools)); err == nil {
		t.Fatalf("forged marker accepted (changed=%v)", forgedChanged)
	}
	// The bytes validator agrees with the map validator on the same input.
	if _, err := production.ValidateToolConstraintPolicy([]byte(forged)); err == nil {
		t.Fatal("bytes validator accepted the forged marker")
	}
}
