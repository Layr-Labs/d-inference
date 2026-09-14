package toolpolicy

import (
	"errors"
	"fmt"
	"testing"
)

func TestValidateToolConstraintRequestModes(t *testing.T) {
	base := `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}}}]`
	tests := []struct {
		name   string
		suffix string
		want   Mode
	}{
		{"auto omitted", `}`, Auto},
		{"auto explicit", `,"tool_choice":"auto"}`, Auto},
		{"none", `,"tool_choice":"none"}`, None},
		{"required", `,"tool_choice":"required"}`, Required},
		{"named nested", `,"tool_choice":{"type":"function","function":{"name":"weather"}}}`, Named},
		{"named responses", `,"tool_choice":{"type":"function","name":"weather"}}`, Named},
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

func TestValidateToolConstraintRequestRejectsProductionFaultClasses(t *testing.T) {
	tests := []struct {
		name string
		body string
		kind ErrorKind
	}{
		{
			"invalid function name",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"bad name"}}],"tool_choice":"required"}`,
			InvalidRequest,
		},
		{
			"named undeclared",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":{"type":"function","function":{"name":"missing"}}}`,
			InvalidRequest,
		},
		{
			"unsupported union",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"oneOf":[{"type":"string"},{"type":"integer"}]}}}}}],"tool_choice":"required"}`,
			UnsupportedSchema,
		},
		{
			"enum type mismatch",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"string","enum":[1]}}}}}],"tool_choice":"required"}`,
			InvalidRequest,
		},
		{
			"number integer beyond exact range",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":9007199254740993}}}}}],"tool_choice":"required"}`,
			UnsupportedSchema,
		},
		{
			"number Int max cannot trap provider",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":9223372036854775807}}}}}],"tool_choice":"required"}`,
			UnsupportedSchema,
		},
		{
			"precision sensitive decimal",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":0.10000000000000001}}}}}],"tool_choice":"required"}`,
			UnsupportedSchema,
		},
		{
			"positive integer-valued float beyond exact range",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":9007199254740994.0}}}}}],"tool_choice":"required"}`,
			UnsupportedSchema,
		},
		{
			"negative integer-valued float beyond exact range",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"number","const":-9007199254740994.0}}}}}],"tool_choice":"required"}`,
			UnsupportedSchema,
		},
		{
			"string parser delimiter",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe","parameters":{"type":"object","properties":{"x":{"type":"string","const":"bad<tool_call|>value"}}}}}],"tool_choice":"required"}`,
			UnsupportedSchema,
		},
		{
			"conflicting named choice",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":{"type":"function","name":"safe","function":{"name":"other"}}}`,
			InvalidRequest,
		},
		{
			"mismatched constrained parser",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":"required","tool_call_parser":"json"}`,
			InvalidRequest,
		},
		{
			"non-object historical arguments",
			`{"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"safe","arguments":"[1]"}}]}]}`,
			InvalidRequest,
		},
		{
			"object-valued historical arguments",
			`{"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"safe","arguments":{"x":1}}}]}]}`,
			InvalidRequest,
		},
		{
			"orphan tool result",
			`{"model":"m","messages":[{"role":"tool","tool_call_id":"missing","content":"x"}]}`,
			InvalidRequest,
		},
		{
			"unanswered mid-history call",
			`{"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[{"id":"c","type":"function","function":{"name":"safe","arguments":"{}"}}]},{"role":"user","content":"next"}]}`,
			InvalidRequest,
		},
		{
			"parallel policy malformed",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tool_choice":"none","parallel_tool_calls":"false"}`,
			InvalidRequest,
		},
		{
			"constrained stop set is bounded",
			`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"safe"}}],"tool_choice":"required","stop":["a","b","c","d","e"]}`,
			InvalidRequest,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := validateToolConstraintRequest([]byte(test.body))
			if err == nil {
				t.Fatal("expected rejection")
			}
			typed, ok := err.(*ValidationError)
			if !ok {
				t.Fatalf("unexpected error type %T: %v", err, err)
			}
			if typed.Kind != test.kind {
				t.Fatalf("kind = %d, want %d (%v)", typed.Kind, test.kind, err)
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
	if mode, err := validateToolConstraintRequest(body); err != nil || mode != Required {
		t.Fatalf("valid supported schema rejected: mode=%q err=%v", mode, err)
	}
}

func TestValidateToolConstraintRequestAcceptsForcedQwenParserAliases(t *testing.T) {
	const prefix = `{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"weather"}}],"tool_choice":"required","tool_call_parser":`
	for _, parser := range []string{
		"qwen3_coder", "qwen3_5", "qwen-xml", "xml_function",
	} {
		t.Run(parser, func(t *testing.T) {
			body := []byte(prefix + fmt.Sprintf("%q}", parser))
			mode, err := validateToolConstraintRequest(body)
			if err != nil || mode != Required {
				t.Fatalf("Qwen parser alias rejected: mode=%q err=%v", mode, err)
			}
		})
	}
}

func TestValidateToolConstraintRequestRejectsReasoningOnlyQwenParser(t *testing.T) {
	body := []byte(`{"model":"m","messages":[{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"weather"}}],"tool_choice":"required","tool_call_parser":"qwen3"}`)
	if _, err := validateToolConstraintRequest(body); err == nil {
		t.Fatal("qwen3 JSON parser unexpectedly accepted for inference-enforced tool choice")
	}
}

func TestValidateToolHistoryAllowsTrailingAssistantContinuation(t *testing.T) {
	body := []byte(`{
		"model":"m",
		"messages":[{
			"role":"assistant",
			"content":"",
			"tool_calls":[{
				"id":"c",
				"type":"function",
				"function":{"name":"safe","arguments":"{}"}
			}]
		}]
	}`)
	if _, err := validateToolConstraintRequest(body); err != nil {
		t.Fatalf("trailing assistant continuation rejected: %v", err)
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
	if err != nil || mode != Named {
		t.Fatalf("unselected unsupported schema rejected named choice: mode=%q err=%v", mode, err)
	}

	_, err = validateToolConstraintRequest(body("unused"))
	var typed *ValidationError
	if !errors.As(err, &typed) || typed.Kind != UnsupportedSchema {
		t.Fatalf("selected unsupported schema accepted: %T %v", err, err)
	}
}

func validateToolConstraintRequest(body []byte) (Mode, error) {
	policy, err := ValidateBytes(body)
	return policy.Mode, err
}
