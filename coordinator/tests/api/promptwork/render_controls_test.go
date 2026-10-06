package promptwork_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPromptShapeRequiresMeasuredReasoningMode(t *testing.T) {
	for _, reasoning := range []string{
		``, `null`, `{}`, `false`, `{"enabled":null}`, `{"enabled":true}`,
		`{"enabled":"false"}`, `{"enabled":0}`, `{"effort":"none"}`,
		`{"enabled":false,"effort":"none"}`, `{"enabled":false,"future_control":false}`,
	} {
		t.Run(reasoning, func(t *testing.T) {
			body := `{"messages":[{"role":"user","content":"same prompt"}]`
			if reasoning != "" {
				body += `,"reasoning":` + reasoning
			}
			if _, ok := production.ShapeFromBody([]byte(body + `}`)); ok {
				t.Fatal("unmeasured reasoning mode borrowed the false-mode corpus")
			}
		})
	}
}

func TestPromptShapeRejectsUnmeasuredRenderingInputs(t *testing.T) {
	for _, field := range []string{
		`"reasoning_effort":"none"`, `"enable_thinking":false`, `"preserve_thinking":false`,
		`"chat_template_kwargs":{}`, `"chat_template":"custom"`, `"add_generation_prompt":false`,
		`"continue_final_message":true`, `"instructions":"extra instructions"`, `"system":"extra system"`,
		`"response_format":{"type":"json_object"}`, `"response_format":{"type":"json_schema","json_schema":{"name":"answer","schema":{"description":"` + strings.Repeat("unmeasured schema ", 1000) + `"}}}`,
		`"functions":[]`, `"function_call":"auto"`, `"future_render_control":null`,
		`"tool_choice":"none"`, `"tool_choice":"required"`,
		`"tool_choice":{"type":"function","function":{"name":"lookup_reference"}}`,
	} {
		t.Run(strings.SplitN(field, ":", 2)[0], func(t *testing.T) {
			body := `{"reasoning":{"enabled":false},"messages":[{"role":"user","content":"same prompt"}],` + field + `}`
			if _, ok := production.ShapeFromBody([]byte(body)); ok {
				t.Fatal("unmeasured prompt control borrowed the measured shape")
			}
		})
	}
	for _, field := range []string{
		`"name":"assistant_name"`, `"name":null`, `"reasoning_content":"hidden history"`,
		`"reasoning":"hidden history"`, `"thinking":"hidden history"`,
		`"function_call":{"name":"lookup_reference","arguments":"{}"}`,
	} {
		t.Run("message/"+field, func(t *testing.T) {
			body := `{"reasoning":{"enabled":false},"messages":[{"role":"assistant","content":"same prompt",` + field + `}]}`
			if _, ok := production.ShapeFromBody([]byte(body)); ok {
				t.Fatal("unmeasured rendered history borrowed the measured shape")
			}
		})
	}
}

func TestPromptShapeKeepsNonRenderingOptions(t *testing.T) {
	for _, fields := range []string{
		``, `,"tool_choice":"auto"`, `,"tool_choice":null`,
		`,"stream":true,"stream_options":{"include_usage":true},"temperature":0.7,"top_p":0.9,"top_k":40,"min_p":0.05,"seed":7,"stop":["end"],"max_tokens":128`,
		`,"max_completion_tokens":128,"presence_penalty":0.1,"frequency_penalty":0.2,"repetition_penalty":1.1,"logit_bias":{"1":-1},"logprobs":true,"top_logprobs":2,"n":1`,
		`,"parallel_tool_calls":false,"tool_call_parser":"qwen3_xml","reasoning_parser":"qwen3"`,
		`,"user":"caller","metadata":{"tag":"test"},"store":false,"service_tier":"auto","safety_identifier":"id","prompt_cache_key":"caller-key","prompt_cache_retention":"24h"`,
		`,"_darkbloom_prompt_date":"2026-09-28"`,
	} {
		t.Run(fields, func(t *testing.T) {
			body := []byte(`{"reasoning": { "enabled" : false },"messages":[{"role":"user","content":"same prompt"}]` + fields + `}`)
			shape, ok := production.ShapeFromBody(body)
			if !ok || shape.BodyBytes != len(body) {
				t.Fatal("inert output/transport options lost the measured rendering mode")
			}
		})
	}
}

func TestPromptShapeRejectsAlternateToolRendering(t *testing.T) {
	for _, tool := range []string{
		`{"type":"function","function":{"name":"lookup_reference","description":7},"name":"alternate","parameters":{"type":"object"}}`,
		`{"type":"function","function":{"name":"lookup_reference","description":false},"name":"alternate","input_schema":{"type":"object"}}`,
		`{"type":"function","function":{"name":null},"name":"alternate"}`,
		`{"type":"function","function":{"name":7}}`,
		`{"type":"function","function":{"name":"lookup_reference","description":7}}`,
		`{"type":"function","function":{"name":"lookup_reference"},"name":"alternate"}`,
	} {
		body := []byte(`{"reasoning":{"enabled":false},"messages":[{"role":"user","content":"same prompt"}],"tools":[` + tool + `]}`)
		if _, known := production.ShapeFromBody(body); known {
			t.Fatalf("unmeasured tool decoding path qualified: %s", tool)
		}
	}
	for _, function := range []string{
		`{"name":null,"arguments":"{}"}`, `{"name":7,"arguments":"{}"}`,
		`{"name":"lookup_reference","arguments":{}}`, `{"name":"lookup_reference","arguments":null}`,
	} {
		body := []byte(`{"reasoning":{"enabled":false},"messages":[{"role":"assistant","content":null,"tool_calls":[{"type":"function","id":"call","function":` + function + `}]}]}`)
		if _, known := production.ShapeFromBody(body); known {
			t.Fatalf("unmeasured tool-call decoding path qualified: %s", function)
		}
	}
}

func TestPromptShapeMeasuredPlainAndToolBodiesReachReviewedFallback(t *testing.T) {
	// Synthetic representatives exercise the real catalog's applicability;
	// they are not additional qualification evidence or fitted coefficients.
	for _, tools := range []bool{false, true} {
		messages := []map[string]any{
			{"role": "system", "content": "Review task 123456789012 carefully."},
			{"role": "user", "content": strings.Repeat("river ", 2500)},
		}
		body := map[string]any{
			"model": "EigenLabs/Qwen3.8-27B-4bit-mtp", "reasoning": map[string]any{"enabled": false},
			"max_tokens": 128, "temperature": 0,
		}
		if tools {
			body["tool_choice"] = "auto"
			body["tools"] = []any{map[string]any{"type": "function", "function": map[string]any{
				"name": "lookup_reference", "description": strings.Repeat("schema ", 80),
				"parameters": map[string]any{"type": "object", "properties": map[string]any{"field_0": map[string]any{"type": "string"}}},
			}}}
			messages = append(messages,
				map[string]any{"role": "assistant", "content": nil, "tool_calls": []any{map[string]any{
					"id": "call_123456789012", "type": "function", "function": map[string]any{"name": "lookup_reference", "arguments": `{"field_0": "amber"}`},
				}}},
				map[string]any{"role": "tool", "tool_call_id": "call_123456789012", "content": strings.Repeat("reference ", 15)},
				map[string]any{"role": "user", "content": "Continue using the retrieved reference."})
		} else {
			messages = append(messages,
				map[string]any{"role": "assistant", "content": "A measured-format prior answer."},
				map[string]any{"role": "user", "content": "Explain the reasoning and check the result."})
		}
		body["messages"] = messages
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		shape, known := production.ShapeFromBody(encoded)
		work := production.Calibrated(body["model"].(string),
			"bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463",
			"2dcff358f55d07c26bf238d15184148b78b50dc277e59ae7ef9a758534687064", 4000, tools, shape)
		if !known || work == nil || work.Source != protocol.PromptWorkCalibrated {
			t.Fatalf("measured rendering mode lost reviewed fallback (tools=%t): known=%t shape=%+v work=%+v", tools, known, shape, work)
		}
	}
}

func TestUnmeasuredPromptRenderingStillUsesExactTokenizer(t *testing.T) {
	body := []byte(`{"reasoning":{"enabled":true},"messages":[{"role":"user","content":"different rendering"}]}`)
	if _, known := production.ShapeFromBody(body); known {
		t.Fatal("test requires an unmeasured fallback rendering mode")
	}
	input := registry.CachePlanInput{PromptContractID: strings.Repeat("b", 64), ModelAggregateSHA256: strings.Repeat("a", 64), Body: body}
	calls := 0
	client := tokenizerFunc(func(_ context.Context, got promptcontract.PlanInput) (promptcontract.Plan, error) {
		calls++
		if string(got.Body) != string(body) {
			t.Fatal("exact tokenizer lost the rendering controls")
		}
		return promptcontract.Plan{Participating: true, PromptContractID: input.PromptContractID, PromptTokenCount: 128}, nil
	})
	result := production.Plan(context.Background(), client, input, production.Heuristic(100), func(context.Context) registry.CachePlanResult { return registry.CachePlanResult{} })
	if calls != 1 || result.Work.Source != protocol.PromptWorkExact || result.Work.PromptTokens != 128 {
		t.Fatalf("fallback domain restriction affected exact accounting: calls=%d result=%+v", calls, result.Work)
	}
}
