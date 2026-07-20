package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestValidateToolConstraintRequestModes(t *testing.T) {
	base := `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}}}]`
	tests := []struct {
		name   string
		suffix string
		want   toolChoiceMode
	}{
		{"auto omitted", `}`, toolChoiceAuto},
		{"auto explicit", `,"tool_choice":"auto"}`, toolChoiceAuto},
		{"none", `,"tool_choice":"none"}`, toolChoiceNone},
		{"required", `,"tool_choice":"required"}`, toolChoiceRequired},
		{"named nested", `,"tool_choice":{"type":"function","function":{"name":"weather"}}}`, toolChoiceNamed},
		{"named responses", `,"tool_choice":{"type":"function","name":"weather"}}`, toolChoiceNamed},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := validateToolConstraintRequest([]byte(base + test.suffix))
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("mode = %q, want %q", got, test.want)
			}
		})
	}
}

func TestInferencePreludeNormalizesSingleStopForSwiftProtocol(t *testing.T) {
	srv, _ := testServer(t)
	request := httptest.NewRequest(
		http.MethodPost,
		"/v1/chat/completions",
		strings.NewReader(
			`{"model":"m","messages":[{"role":"user","content":"x"}],"stop":"END"}`))
	response := httptest.NewRecorder()
	prelude, ok := srv.parseInferencePrelude(response, request)
	if !ok {
		t.Fatalf("prelude failed: %s", response.Body.String())
	}
	var forwarded map[string]any
	if err := json.Unmarshal(prelude.rawBody, &forwarded); err != nil {
		t.Fatal(err)
	}
	stops, ok := forwarded["stop"].([]any)
	if !ok || len(stops) != 1 || stops[0] != "END" {
		t.Fatalf("forwarded stop = %#v", forwarded["stop"])
	}
}

func TestValidateToolConstraintRequestRejectsProductionFaultClasses(t *testing.T) {
	tests := []struct {
		name   string
		body   string
		status int
	}{
		{
			"invalid function name",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"bad name"}}],"tool_choice":"required"}`,
			http.StatusBadRequest,
		},
		{
			"named undeclared",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":{"type":"function","function":{"name":"missing"}}}`,
			http.StatusBadRequest,
		},
		{
			"unsupported union",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"oneOf":[{"type":"string"},{"type":"integer"}]}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"enum type mismatch",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"string","enum":[1]}}}}}],"tool_choice":"required"}`,
			http.StatusBadRequest,
		},
		{
			"number integer beyond exact range",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":9007199254740993}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"number Int max cannot trap provider",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":9223372036854775807}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"precision sensitive decimal",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":0.10000000000000001}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"positive integer-valued float beyond exact range",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":9007199254740994.0}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"negative integer-valued float beyond exact range",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":-9007199254740994.0}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"string parser delimiter",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"string","const":"bad<tool_call|>value"}}}}}],"tool_choice":"required"}`,
			http.StatusUnprocessableEntity,
		},
		{
			"conflicting named choice",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":{"type":"function","name":"safe","function":{"name":"other"}}}`,
			http.StatusBadRequest,
		},
		{
			"mismatched constrained parser",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":"required","tool_call_parser":"json"}`,
			http.StatusBadRequest,
		},
		{
			"non-object historical arguments",
			`{"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"safe","arguments":"[1]"}}]}]}`,
			http.StatusBadRequest,
		},
		{
			"object-valued historical arguments",
			`{"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"safe","arguments":{"x":1}}}]}]}`,
			http.StatusBadRequest,
		},
		{
			"orphan tool result",
			`{"model":"m","messages":[{"role":"tool","tool_call_id":"missing","content":"x"}]}`,
			http.StatusBadRequest,
		},
		{
			"unanswered mid-history call",
			`{"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"safe","arguments":"{}"}}]},{"role":"user","content":"next"}]}`,
			http.StatusBadRequest,
		},
		{
			"parallel policy malformed",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tool_choice":"none","parallel_tool_calls":"false"}`,
			http.StatusBadRequest,
		},
		{
			"constrained stop set is bounded",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":"required","stop":["a","b","c","d","e"]}`,
			http.StatusBadRequest,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := validateToolConstraintRequest([]byte(test.body))
			if err == nil {
				t.Fatal("expected rejection")
			}
			typed, ok := err.(*toolConstraintRequestError)
			if !ok {
				t.Fatalf("unexpected error type %T: %v", err, err)
			}
			if typed.status != test.status {
				t.Fatalf("status = %d, want %d (%v)", typed.status, test.status, err)
			}
		})
	}
}

func TestValidateToolConstraintRequestAcceptsNormalizedSubset(t *testing.T) {
	body := []byte(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"parallel_tool_calls":false,
		"tools":[{"type":"function","function":{
			"name":"weather",
			"parameters":{
				"properties":{
					"city":{"type":"string","enum":["Paris","Tokyo"]},
					"days":{"type":["integer","null"]},
					"units":{"type":"array","items":{"type":"string"},"maxItems":3}
				},
				"required":["city"],
				"additionalProperties":false
			}
		}}],
		"tool_choice":"required"
	}`)
	if mode, err := validateToolConstraintRequest(body); err != nil || mode != toolChoiceRequired {
		t.Fatalf("valid supported schema rejected: mode=%q err=%v", mode, err)
	}
}

func TestNamedToolChoiceValidatesOnlySelectedSchema(t *testing.T) {
	body := func(choice string) []byte {
		return []byte(fmt.Sprintf(`{
		"model":"m",
		"messages":[{"role":"user","content":"x"}],
		"tools":[
			{"type":"function","function":{
				"name":"selected",
				"parameters":{"type":"object","properties":{"value":{"type":"string"}}}
			}},
			{"type":"function","function":{
				"name":"unused",
				"parameters":{"type":"object","properties":{"value":{"pattern":"^x$"}}}
			}}
		],
		"tool_choice":{"type":"function","function":{"name":%q}}
	}`, choice))
	}
	mode, err := validateToolConstraintRequest(body("selected"))
	if err != nil || mode != toolChoiceNamed {
		t.Fatalf("unselected unsupported schema rejected named choice: mode=%q err=%v", mode, err)
	}

	_, err = validateToolConstraintRequest(body("unused"))
	var typed *toolConstraintRequestError
	if !errors.As(err, &typed) || typed.status != http.StatusUnprocessableEntity {
		t.Fatalf("selected unsupported schema accepted: %T %v", err, err)
	}
}

func TestValidateToolConstraintRequestRejectsProviderGrammarExplosion(t *testing.T) {
	var value any = map[string]any{"type": "string"}
	for range 4 {
		value = map[string]any{
			"type":     "array",
			"items":    value,
			"maxItems": 16,
		}
	}
	body, err := json.Marshal(map[string]any{
		"model":    "m",
		"messages": []any{map[string]any{"role": "user", "content": "x"}},
		"tools": []any{map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": "expand",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"value": value,
					},
				},
			},
		}},
		"tool_choice": "required",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, validationErr := validateToolConstraintRequest(body)
	var typed *toolConstraintRequestError
	if !errors.As(validationErr, &typed) {
		t.Fatalf("expected typed complexity rejection, got %T: %v", validationErr, validationErr)
	}
	if typed.status != http.StatusUnprocessableEntity ||
		!strings.Contains(typed.message, "grammar exceeds") {
		t.Fatalf("unexpected complexity rejection: %+v", typed)
	}
}

func TestValidateToolConstraintRequestRejectsNullArrayBounds(t *testing.T) {
	for _, bound := range []string{"minItems", "maxItems"} {
		t.Run(bound, func(t *testing.T) {
			body := []byte(fmt.Sprintf(`{
				"model":"m",
				"messages":[{"role":"user","content":"x"}],
				"tools":[{"type":"function","function":{
					"name":"expand",
					"parameters":{
						"type":"object",
						"properties":{
							"values":{"type":"array","items":{"type":"string"},"%s":null}
						}
					}
				}}],
				"tool_choice":"required"
			}`, bound))
			_, err := validateToolConstraintRequest(body)
			var typed *toolConstraintRequestError
			if !errors.As(err, &typed) || typed.status != http.StatusBadRequest {
				t.Fatalf("null %s accepted: %T %v", bound, err, err)
			}
		})
	}
}

func TestValidateToolConstraintRequestChargesNullableBranches(t *testing.T) {
	properties := make(map[string]any, 128)
	for index := range 128 {
		properties[fmt.Sprintf("p%d", index)] = map[string]any{
			"type": []any{"string", "null"},
			"enum": []any{nil},
		}
	}
	tools := make([]any, 64)
	for index := range tools {
		tools[index] = map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": fmt.Sprintf("tool%d", index),
				"parameters": map[string]any{
					"type":       "object",
					"properties": properties,
				},
			},
		}
	}
	body, err := json.Marshal(map[string]any{
		"model":       "m",
		"messages":    []any{map[string]any{"role": "user", "content": "x"}},
		"tools":       tools,
		"tool_choice": "required",
	})
	if err != nil {
		t.Fatal(err)
	}
	_, validationErr := validateToolConstraintRequest(body)
	var typed *toolConstraintRequestError
	if !errors.As(validationErr, &typed) ||
		typed.status != http.StatusUnprocessableEntity ||
		!strings.Contains(typed.message, "grammar exceeds") {
		t.Fatalf("nullable grammar undercharged: %T %v", validationErr, validationErr)
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
	if mode, err := validateToolConstraintRequest(responses); err != nil || mode != toolChoiceNamed {
		t.Fatalf("Responses constraint lost: mode=%q err=%v body=%s", mode, err, responses)
	}

	messages, err := promptcontract.LowerProviderBody(
		promptcontract.EndpointMessages,
		[]byte(`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"name":"weather","input_schema":{"type":"object"}}],"tool_choice":{"type":"any","disable_parallel_tool_use":true}}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	if mode, err := validateToolConstraintRequest(messages); err != nil || mode != toolChoiceRequired {
		t.Fatalf("Messages constraint lost: mode=%q err=%v body=%s", mode, err, messages)
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
	if _, err := validateToolConstraintRequest(parallelHistory); err != nil {
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
			if _, err := validateToolConstraintRequest(body); err != nil {
				t.Fatalf("pre-normalization validation: %v", err)
			}
			normalized := NormalizeToolSchemas(body)
			if _, err := validateToolConstraintRequest(normalized); err != nil {
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

func TestResponsesEchoEnforcedToolPolicy(t *testing.T) {
	traits := registry.RequestTraits{
		ToolChoiceMode:    string(toolChoiceNamed),
		ToolChoiceName:    "weather",
		ParallelToolCalls: false,
	}
	snapshot := responsesSnapshot(
		"resp", 1, "model", "in_progress", nil, nil, nil, traits)
	if snapshot["parallel_tool_calls"] != false {
		t.Fatalf("stream snapshot lost parallel policy: %#v", snapshot)
	}
	choice, ok := snapshot["tool_choice"].(map[string]any)
	if !ok || choice["type"] != "function" || choice["name"] != "weather" {
		t.Fatalf("stream snapshot lost named choice: %#v", snapshot)
	}
	response := buildResponsesResponse(
		"request", "model", extractedMessage{Content: "ok"},
		protocol.UsageInfo{}, 16, "", "", traits)
	if response.ParallelToolCalls || response.ToolChoice == nil {
		t.Fatalf("nonstreaming response lost tool policy: %+v", response)
	}
}
