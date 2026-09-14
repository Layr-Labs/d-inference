package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestInferencePreludeNormalizesSingleStopForSwiftProtocol(t *testing.T) {
	srv, _ := testServer(t)
	request := httptest.NewRequest(
		http.MethodPost,
		"/v1/chat/completions",
		strings.NewReader(
			`{"model":"m","messages":[{"role":"user","content":"x"}],"stop":"END","metadata":{"exact":9007199254740993,"decimal":0.10000000000000001}}`))
	response := httptest.NewRecorder()
	prelude, ok := srv.parseInferencePrelude(response, request)
	if !ok {
		t.Fatalf("prelude failed: %s", response.Body.String())
	}
	if !prelude.body.dirty {
		t.Fatal("stop normalization did not mark the forward body dirty")
	}
	rawBody, err := prelude.body.current()
	if err != nil {
		t.Fatal(err)
	}
	var forwarded map[string]any
	if err := json.Unmarshal(rawBody, &forwarded); err != nil {
		t.Fatal(err)
	}
	stops, ok := forwarded["stop"].([]any)
	if !ok || len(stops) != 1 || stops[0] != "END" {
		t.Fatalf("forwarded stop = %#v", forwarded["stop"])
	}
	for _, literal := range []string{"9007199254740993", "0.10000000000000001"} {
		if !bytes.Contains(rawBody, []byte(literal)) {
			t.Fatalf("forwarded body lost exact numeric literal %s: %s", literal, rawBody)
		}
	}
}

func TestValidateResolvedToolConstraintParserBindsModelFamily(t *testing.T) {
	tests := []struct {
		name              string
		parser            string
		modelID           string
		modelType         string
		runtimeParameters map[string]any
		wantError         bool
	}{
		{
			name:   "Qwen parser on Qwen",
			parser: "qwen3_coder", modelID: registry.Qwen38NAXModelID,
		},
		{
			name:   "Gemma parser on Qwen",
			parser: "gemma", modelID: registry.Qwen38NAXModelID, wantError: true,
		},
		{
			name:   "Gemma parser on Gemma",
			parser: "gemma4", modelType: "gemma4",
		},
		{
			name:   "Qwen parser on Gemma",
			parser: "qwen_xml", modelType: "gemma4_text", wantError: true,
		},
		{
			name:   "runtime default defines family",
			parser: "qwen3_coder", modelID: "opaque-build",
			runtimeParameters: map[string]any{"tool_call_parser": "qwen3_coder"},
		},
		{
			name:   "runtime default rejects other family",
			parser: "gemma", modelID: "opaque-build",
			runtimeParameters: map[string]any{"tool_call_parser": "qwen3_coder"},
			wantError:         true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateResolvedToolConstraintParser(
				map[string]any{"tool_call_parser": test.parser},
				toolpolicy.Required,
				test.modelID,
				test.modelType,
				test.runtimeParameters,
			)
			if test.wantError && err == nil {
				t.Fatal("mismatched parser unexpectedly accepted")
			}
			if !test.wantError && err != nil {
				t.Fatalf("matching parser rejected: %v", err)
			}
		})
	}
}

func TestEndpointLoweringPreservesConstraintAndParallelPolicy(t *testing.T) {
	responses, err := promptcontract.LowerProviderBody(
		promptcontract.EndpointResponses,
		[]byte(`{"model":"m","input":"x","tools":[{"type":"function","name":"weather","parameters":{"type":"object"}}],"tool_choice":{"type":"function","name":"weather"},"parallel_tool_calls":false}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	if mode, err := toolpolicy.ValidateBytes(responses); err != nil || mode.Mode != toolpolicy.Named {
		t.Fatalf("Responses constraint lost: mode=%q err=%v body=%s", mode.Mode, err, responses)
	}

	messages, err := promptcontract.LowerProviderBody(
		promptcontract.EndpointMessages,
		[]byte(`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"name":"weather","input_schema":{"type":"object"}}],"tool_choice":{"type":"any","disable_parallel_tool_use":true}}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	if mode, err := toolpolicy.ValidateBytes(messages); err != nil || mode.Mode != toolpolicy.Required {
		t.Fatalf("Messages constraint lost: mode=%q err=%v body=%s", mode.Mode, err, messages)
	}
	var lowered map[string]any
	if err := jsonUnmarshalUseNumber(messages, &lowered); err != nil {
		t.Fatal(err)
	}
	if parallel, ok := lowered["parallel_tool_calls"].(bool); !ok || parallel {
		t.Fatalf("disable_parallel_tool_use was not preserved: %v", lowered)
	}

	parallelHistory, err := promptcontract.LowerProviderBody(
		promptcontract.EndpointResponses,
		[]byte(`{"model":"m","input":[
			{"type":"function_call","call_id":"a","name":"weather","arguments":"{}"},
			{"type":"function_call","call_id":"b","name":"weather","arguments":"{}"},
			{"type":"function_call_output","call_id":"a","output":"A"},
			{"type":"function_call_output","call_id":"b","output":"B"}
		]}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := toolpolicy.ValidateBytes(parallelHistory); err != nil {
		t.Fatalf("valid parallel Responses history rejected: %v\n%s", err, parallelHistory)
	}
}

func TestNullableUnionSurvivesEveryEndpointNormalization(t *testing.T) {
	schema := `{"type":"object","properties":{"value":{"type":["STRING","NULL"],"nullable":false,"enum":[null]}}}`
	tests := []struct {
		name     string
		endpoint promptcontract.Endpoint
		body     string
		lower    bool
	}{
		{
			name: "chat",
			body: `{"model":"m","messages":[{"role":"user","content":"x"}],` +
				`"tools":[{"type":"function","function":{"name":"f","parameters":` +
				schema + `}}],"tool_choice":"required"}`,
		},
		{
			name: "responses", endpoint: promptcontract.EndpointResponses, lower: true,
			body: `{"model":"m","input":"x","tools":[{"type":"function","name":"f","parameters":` +
				schema + `}],"tool_choice":"required"}`,
		},
		{
			name: "messages", endpoint: promptcontract.EndpointMessages, lower: true,
			body: `{"model":"m","messages":[{"role":"user","content":"x"}],` +
				`"tools":[{"name":"f","input_schema":` + schema +
				`}],"tool_choice":{"type":"any"}}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			body := []byte(test.body)
			if test.lower {
				var err error
				body, err = promptcontract.LowerProviderBody(
					test.endpoint, body)
				if err != nil {
					t.Fatal(err)
				}
			}
			if _, err := toolpolicy.ValidateBytes(body); err != nil {
				t.Fatalf("pre-normalization validation: %v", err)
			}
			normalized := toolpolicy.NormalizeBytes(body)
			if _, err := toolpolicy.ValidateBytes(normalized); err != nil {
				t.Fatalf("post-normalization validation: %v\n%s", err, normalized)
			}
			var root map[string]any
			if err := json.Unmarshal(normalized, &root); err != nil {
				t.Fatal(err)
			}
			tools := root["tools"].([]any)
			function := tools[0].(map[string]any)["function"].(map[string]any)
			parameters := function["parameters"].(map[string]any)
			properties := parameters["properties"].(map[string]any)
			value := properties["value"].(map[string]any)
			if value["nullable"] != true {
				t.Fatalf("nullable union was lost: %#v", value)
			}
		})
	}
}

func jsonUnmarshalUseNumber(body []byte, output any) error {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	return decoder.Decode(output)
}
