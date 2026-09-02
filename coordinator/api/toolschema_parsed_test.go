package api

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
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
	"no tools":        `{"model":"m","messages":[{"role":"user","content":"the word \"tools\" in text"}]}`,
	"tools not array": `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":{"type":"function"}}`,
	"scalar tool":     `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":["nope",1,null]}`,
	"numbers preserved": `{"model":"m","messages":[{"role":"user","content":"x"}],"metadata":{"exact":9007199254740993,"decimal":0.10000000000000001},
		"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"description":"text","default":1e400}}}}}]}`,
	"invalid utf8 in messages and keys": "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"bad \xff\xfe bytes\",\"na\xffme\":\"v\xe2\x82\"}]," +
		`"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"q":{"description":"text"}}}}}]}`,
}

func decodeForParity(t *testing.T, body string) map[string]any {
	t.Helper()
	parsed, err := decodeInferenceJSONObject([]byte(body))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	return parsed
}

// The parsed-map normalization must leave the handler with exactly the map
// the bytes path produced (decode(NormalizeToolSchemas(body))), marshal to the
// same provider bytes, and hand back the caller's tools untouched.
func TestNormalizeParsedToolSchemasMatchesBytesPath(t *testing.T) {
	for name, body := range toolNormalizationParityBodies {
		t.Run(name, func(t *testing.T) {
			raw := []byte(body)
			normalizedBytes := NormalizeToolSchemas(raw)
			bytesChanged := !bytes.Equal(normalizedBytes, raw)
			wantParsed := decodeForParity(t, string(normalizedBytes))
			wantForward, err := marshalForwardBody(wantParsed)
			if err != nil {
				t.Fatal(err)
			}

			parsed := decodeForParity(t, body)
			wantOriginalTools := decodeForParity(t, body)["tools"]
			originalTools, changed := normalizeParsedToolSchemas(parsed, len(raw))
			if changed != bytesChanged {
				t.Fatalf("changed = %v, bytes path changed = %v", changed, bytesChanged)
			}
			if !reflect.DeepEqual(parsed, wantParsed) {
				t.Fatalf("parsed tree diverged from bytes path:\n got %#v\nwant %#v", parsed, wantParsed)
			}
			gotForward, err := marshalForwardBody(parsed)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(gotForward, wantForward) {
				t.Fatalf("forward bytes diverged:\n got %s\nwant %s", gotForward, wantForward)
			}
			if !changed {
				if originalTools != nil {
					t.Fatalf("unchanged body returned original tools %#v", originalTools)
				}
				return
			}
			if !reflect.DeepEqual(any(originalTools), wantOriginalTools) {
				t.Fatalf("original tools were mutated:\n got %#v\nwant %#v", originalTools, wantOriginalTools)
			}
		})
	}
}

func TestNormalizeParsedToolSchemasRespectsSizeGate(t *testing.T) {
	body := toolNormalizationParityBodies["chat missing type"]
	parsed := decodeForParity(t, body)
	before := cloneJSONValue(parsed)
	if _, changed := normalizeParsedToolSchemas(parsed, maxToolNormalizationBytes+1); changed {
		t.Fatal("oversize body was normalized")
	}
	if !reflect.DeepEqual(parsed, before) {
		t.Fatal("oversize body was mutated")
	}
	// The bytes path skips the same bodies.
	padded := append([]byte(body), bytes.Repeat([]byte(" "), maxToolNormalizationBytes)...)
	if got := NormalizeToolSchemas(padded); !bytes.Equal(got, padded) {
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
	originalTools, changed := normalizeParsedToolSchemas(parsed, len(body))
	if !changed || originalTools == nil {
		t.Fatal("boolean positional schema was not repaired")
	}
	// The repaired copy now carries the reserved marker …
	repaired, _ := marshalForwardBody(parsed["tools"])
	if !bytes.Contains(repaired, []byte(originalBooleanSchemaKey)) {
		t.Fatalf("repaired tools lack the marker: %s", repaired)
	}
	// … so validating the repaired view would wrongly reject the request …
	if _, err := validateParsedToolConstraintPolicy(parsed); err == nil {
		t.Fatal("repaired view accepted (marker not detected); test premise broken")
	}
	// … while the original view (what the handler validates) accepts it.
	view := constraintView(parsed, originalTools)
	if _, err := validateParsedToolConstraintPolicy(view); err != nil {
		t.Fatalf("original view rejected: %v", err)
	}
	// And a genuinely forged marker in the caller's body still fails closed.
	forged := strings.Replace(body, `"any":true`, `"any":{"type":"string","`+originalBooleanSchemaKey+`":true}`, 1)
	forgedParsed := decodeForParity(t, forged)
	forgedTools, forgedChanged := normalizeParsedToolSchemas(forgedParsed, len(forged))
	if _, err := validateParsedToolConstraintPolicy(constraintView(forgedParsed, forgedTools)); err == nil {
		t.Fatalf("forged marker accepted (changed=%v)", forgedChanged)
	}
	// The bytes validator agrees with the map validator on the same input.
	if _, err := validateToolConstraintPolicy([]byte(forged)); err == nil {
		t.Fatal("bytes validator accepted the forged marker")
	}
}

// The bytes and parsed validators must return identical verdicts for the
// constraint test corpus.
func TestParsedAndBytesConstraintValidatorsAgree(t *testing.T) {
	bodies := []string{
		`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"required"}`,
		`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"weather"}}],"tool_choice":{"type":"function","function":{"name":"weather"}},"parallel_tool_calls":false}`,
		`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"bad name"}}],"tool_choice":"required"}`,
		`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":{"type":"function","function":{"name":"missing"}}}`,
		`{"model":"m","messages":[{"role":"user","content":"x"}],"stop":"END","tools":[{"type":"function","function":{"name":"f"}}],"tool_choice":"required"}`,
		`{"model":"m","messages":[{"role":"user","content":"x"}],"stop":["a","b","c","d","e"],"tools":[{"type":"function","function":{"name":"f"}}],"tool_choice":"required"}`,
		`{"model":"m","messages":[{"role":"user","content":"x"}],"tool_call_parser":"unknown","tools":[{"type":"function","function":{"name":"f"}}],"tool_choice":"required"}`,
		`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":"nope"}`,
		`{"model":"m","messages":[{"role":"user","content":"x"}]}`,
	}
	for i, body := range bodies {
		wantPolicy, wantErr := validateToolConstraintPolicy([]byte(body))
		gotPolicy, gotErr := validateParsedToolConstraintPolicy(decodeForParity(t, body))
		if gotPolicy != wantPolicy || !reflect.DeepEqual(gotErr, wantErr) {
			t.Errorf("body %d: parsed=(%+v, %v) bytes=(%+v, %v)", i, gotPolicy, gotErr, wantPolicy, wantErr)
		}
	}
	if _, err := validateToolConstraintPolicy([]byte(`not json`)); err == nil || err.Error() != "invalid request body" {
		t.Fatalf("bytes validator lost its decode error: %v", err)
	}
}

func TestSanitizeInvalidUTF8MatchesEncoderRoundTrip(t *testing.T) {
	tree := map[string]any{
		"ok":         "plain",
		"bad\xff":    "v\xe2\x82",
		"nested":     []any{"\xff\xff", map[string]any{"k\xfe": "\xc0\xaf"}, json.Number("1")},
		"valid rune": "\uFFFD\u2028\u2029",
	}
	encoded, err := json.Marshal(tree)
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]any
	dec := json.NewDecoder(bytes.NewReader(encoded))
	dec.UseNumber()
	if err := dec.Decode(&want); err != nil {
		t.Fatal(err)
	}
	got := sanitizeInvalidUTF8(cloneJSONValue(tree))
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sanitized tree = %#v, want round-tripped %#v", got, want)
	}
	// Valid strings are returned as-is (no copy).
	valid := "already fine"
	if out := sanitizeInvalidUTF8(valid); out != valid {
		t.Fatalf("valid string rewritten: %q", out)
	}
}
