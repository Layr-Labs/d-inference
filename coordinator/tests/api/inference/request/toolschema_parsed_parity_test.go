package request_test

import (
	"bytes"
	"reflect"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// publicToolNormalizationParityBodies cover every schema home and repair class the
// normalizer handles, plus the gates it must respect. Each is paired with a
// message history so the whole-body round trip (not just the tools) is
// compared.
var publicToolNormalizationParityBodies = map[string]string{
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

func publicDecodeForParity(t *testing.T, body string) map[string]any {
	t.Helper()
	parsed, err := inreq.DecodeInferenceJSONObject([]byte(body))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	return parsed
}

// The parsed-map normalization must leave the handler with exactly the map
// the bytes path produced (decode(NormalizeToolSchemas(body))), marshal to the
// same provider bytes, and hand back the caller's tools untouched.
func TestNormalizeParsedToolSchemasMatchesBytesPath(t *testing.T) {
	for name, body := range publicToolNormalizationParityBodies {
		t.Run(name, func(t *testing.T) {
			raw := []byte(body)
			normalizedBytes := inreq.NormalizeToolSchemas(raw)
			bytesChanged := !bytes.Equal(normalizedBytes, raw)
			wantParsed := publicDecodeForParity(t, string(normalizedBytes))
			wantForward, err := inreq.MarshalForwardBody(wantParsed)
			if err != nil {
				t.Fatal(err)
			}

			parsed := publicDecodeForParity(t, body)
			wantOriginalTools := publicDecodeForParity(t, body)["tools"]
			originalTools, changed := inreq.NormalizeParsedToolSchemas(parsed, raw)
			if changed != bytesChanged {
				t.Fatalf("changed = %v, bytes path changed = %v", changed, bytesChanged)
			}
			if !reflect.DeepEqual(parsed, wantParsed) {
				t.Fatalf("parsed tree diverged from bytes path:\n got %#v\nwant %#v", parsed, wantParsed)
			}
			gotForward, err := inreq.MarshalForwardBody(parsed)
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
		wantPolicy, wantErr := inreq.ValidateToolConstraintPolicy([]byte(body))
		gotPolicy, gotErr := inreq.ValidateParsedToolConstraintPolicy(publicDecodeForParity(t, body))
		if gotPolicy != wantPolicy || !reflect.DeepEqual(gotErr, wantErr) {
			t.Errorf("body %d: parsed=(%+v, %v) bytes=(%+v, %v)", i, gotPolicy, gotErr, wantPolicy, wantErr)
		}
	}
	if _, err := inreq.ValidateToolConstraintPolicy([]byte(`not json`)); err == nil || err.Error() != "invalid request body" {
		t.Fatalf("bytes validator lost its decode error: %v", err)
	}
}
