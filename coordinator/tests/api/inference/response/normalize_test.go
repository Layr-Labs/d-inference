package response_test

import (
	"encoding/json"
	"math"
	"reflect"
	"strconv"
	"strings"
	"testing"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestExtractMessage(t *testing.T) {
	chunks := []string{
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
		"data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n",
	}

	msg := inresp.ExtractMessage(chunks)
	if msg.Content != "Hello world" {
		t.Errorf("content = %q, want %q", msg.Content, "Hello world")
	}
	if len(msg.ToolCalls) != 0 {
		t.Errorf("tool_calls = %v, want empty", msg.ToolCalls)
	}
}

func TestExtractMessageEmpty(t *testing.T) {
	msg := inresp.ExtractMessage(nil)
	if msg.Content != "" {
		t.Errorf("content = %q, want empty", msg.Content)
	}
}

func TestExtractMessageWithToolCalls(t *testing.T) {
	chunks := []string{
		`data: {"choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"lo"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"cation\":"}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"SF\"}"}}]}}]}`,
	}

	msg := inresp.ExtractMessage(chunks)
	if msg.Content != "" {
		t.Errorf("content = %q, want empty", msg.Content)
	}
	if len(msg.ToolCalls) != 1 {
		t.Fatalf("tool_calls length = %d, want 1", len(msg.ToolCalls))
	}
	tc := msg.ToolCalls[0]
	if tc["id"] != "call_abc" {
		t.Errorf("tool_call id = %v, want call_abc", tc["id"])
	}
	fn := tc["function"].(map[string]any)
	if fn["name"] != "get_weather" {
		t.Errorf("function name = %v, want get_weather", fn["name"])
	}
	if fn["arguments"] != `{"location":"SF"}` {
		t.Errorf("function arguments = %v, want {\"location\":\"SF\"}", fn["arguments"])
	}
}

func TestNormalizeCompleteChatResponse(t *testing.T) {
	resp := map[string]any{
		"id":     "chatcmpl-1",
		"object": "chat.completion",
		"model":  "/Users/provider/.cache/huggingface/hub/models--mlx-community--MiniMax-M2.5-8bit/snapshots/main",
		"choices": []any{
			map[string]any{
				"index": 0,
				"message": map[string]any{
					"role":              "assistant",
					"content":           "<think>work through it</think>\n\n4",
					"reasoning_content": "existing reasoning",
					"tool_calls":        nil,
				},
			},
		},
		"system_fingerprint": nil,
	}

	inresp.NormalizeCompleteChatResponse(resp, "mlx-community/MiniMax-M2.5-8bit")

	if resp["model"] != "mlx-community/MiniMax-M2.5-8bit" {
		t.Fatalf("model = %v", resp["model"])
	}
	if _, ok := resp["system_fingerprint"]; ok {
		t.Fatalf("system_fingerprint should be removed: %#v", resp)
	}
	message := resp["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if message["content"] != "4" {
		t.Fatalf("content = %q, want 4", message["content"])
	}
	reasoning := message["reasoning"].(string)
	if message["reasoning_content"] != reasoning {
		t.Fatalf("reasoning_content = %v, want synchronized reasoning %q", message["reasoning_content"], reasoning)
	}
	if _, ok := message["tool_calls"]; ok {
		t.Fatalf("null tool_calls should be removed: %#v", message)
	}
	if !strings.Contains(reasoning, "existing reasoning") || !strings.Contains(reasoning, "work through it") {
		t.Fatalf("reasoning was not merged correctly: %q", reasoning)
	}
	details := message["reasoning_details"].([]types.ReasoningDetail)
	if len(details) != 1 || details[0].Text != reasoning || details[0].ID != "reasoning-text-0" {
		t.Fatalf("reasoning_details = %#v, want full merged reasoning", details)
	}
}

func TestNormalizeCompleteChatResponseNullContent(t *testing.T) {
	resp := map[string]any{
		"object": "chat.completion",
		"choices": []any{
			map[string]any{
				"message": map[string]any{
					"role":    "assistant",
					"content": nil,
				},
			},
		},
	}

	inresp.NormalizeCompleteChatResponse(resp, "test-model")

	message := resp["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if message["content"] != "" {
		t.Fatalf("content = %v, want empty string", message["content"])
	}
}

func TestNormalizeCompleteChatResponseReasoningDetails(t *testing.T) {
	existingDetails := []any{map[string]any{"type": "provider.custom", "opaque": "value"}}
	resp := map[string]any{
		"object": "chat.completion",
		"choices": []any{
			map[string]any{"index": float64(4), "message": map[string]any{"content": "answer", "reasoning": "full thought"}},
			map[string]any{"index": float64(9), "message": map[string]any{"content": "answer", "reasoning_content": "provider thought", "reasoning_details": existingDetails}},
			map[string]any{"index": float64(11), "message": map[string]any{"content": "answer", "reasoning": ""}},
			map[string]any{"index": float64(12), "message": map[string]any{"content": "answer", "reasoning": "legacy", "reasoning_content": "canonical"}},
		},
	}

	inresp.NormalizeCompleteChatResponse(resp, "test-model")
	choices := resp["choices"].([]any)
	first := choices[0].(map[string]any)["message"].(map[string]any)
	if first["reasoning_content"] != "full thought" {
		t.Fatalf("reasoning aliases not synchronized: %#v", first)
	}
	firstDetail := first["reasoning_details"].([]types.ReasoningDetail)
	if len(firstDetail) != 1 || firstDetail[0].Text != "full thought" || firstDetail[0].ID != "reasoning-text-4" || firstDetail[0].Signature != nil {
		t.Fatalf("canonical reasoning_details = %#v", firstDetail)
	}
	second := choices[1].(map[string]any)["message"].(map[string]any)
	if second["reasoning"] != "provider thought" || second["reasoning_content"] != "provider thought" {
		t.Fatalf("reasoning aliases not synchronized: %#v", second)
	}
	preserved := second["reasoning_details"].([]any)
	if len(preserved) != 1 || preserved[0].(map[string]any)["type"] != "provider.custom" || preserved[0].(map[string]any)["opaque"] != "value" {
		t.Fatalf("existing reasoning_details changed: %#v", preserved)
	}
	third := choices[2].(map[string]any)["message"].(map[string]any)
	if _, ok := third["reasoning_details"]; ok {
		t.Fatalf("empty reasoning added details: %#v", third)
	}
	fourth := choices[3].(map[string]any)["message"].(map[string]any)
	merged := "legacy\n\ncanonical"
	if fourth["reasoning"] != merged || fourth["reasoning_content"] != merged {
		t.Fatalf("complete aliases did not retain both values: %#v", fourth)
	}
	fourthDetail := fourth["reasoning_details"].([]types.ReasoningDetail)
	if len(fourthDetail) != 1 || fourthDetail[0].Text != merged || fourthDetail[0].ID != "reasoning-text-12" {
		t.Fatalf("conflicting alias details = %#v", fourthDetail)
	}
}

func TestNormalizeCompleteChatResponseInvalidChoiceIndexes(t *testing.T) {
	resp := map[string]any{
		"object": "chat.completion",
		"choices": []any{
			map[string]any{"index": float64(-1), "message": map[string]any{"reasoning": "a"}},
			map[string]any{"index": 1.5, "message": map[string]any{"reasoning": "b"}},
			map[string]any{"index": math.NaN(), "message": map[string]any{"reasoning": "c"}},
			map[string]any{"index": math.Inf(1), "message": map[string]any{"reasoning": "d"}},
			map[string]any{"index": int64(-2), "message": map[string]any{"reasoning": "e"}},
		},
	}

	inresp.NormalizeCompleteChatResponse(resp, "test-model")
	for position, rawChoice := range resp["choices"].([]any) {
		message := rawChoice.(map[string]any)["message"].(map[string]any)
		detail := message["reasoning_details"].([]types.ReasoningDetail)[0]
		wantID := "reasoning-text-" + strconv.Itoa(position)
		if detail.ID != wantID {
			t.Fatalf("choice %d detail ID = %q, want %q", position, detail.ID, wantID)
		}
	}
}

func TestNormalizeCompleteChatResponseConflictPreservesResponsesReasoning(t *testing.T) {
	resp := map[string]any{
		"id":      "chatcmpl-conflict",
		"object":  "chat.completion",
		"created": float64(123),
		"choices": []any{map[string]any{
			"index": float64(0),
			"message": map[string]any{
				"content":           "answer",
				"reasoning":         "legacy",
				"reasoning_content": "canonical",
			},
			"finish_reason": "stop",
		}},
		"usage": map[string]any{},
	}
	inresp.NormalizeCompleteChatResponse(resp, "test-model")

	wire, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal normalized chat response: %v", err)
	}
	var chat types.ChatCompletionResponse
	if err := json.Unmarshal(wire, &chat); err != nil {
		t.Fatalf("decode normalized chat response: %v", err)
	}
	converted := inresp.ChatCompletionToResponses(chat, "test-model", "", "")
	reasoningItem := converted.Output[0].(map[string]any)
	summary := reasoningItem["summary"].([]map[string]any)
	if summary[0]["text"] != "legacy\n\ncanonical" {
		t.Fatalf("Responses reasoning = %q, want old merged value", summary[0]["text"])
	}
	convertedWire, err := json.Marshal(converted)
	if err != nil {
		t.Fatalf("marshal Responses conversion: %v", err)
	}
	if strings.Contains(string(convertedWire), "reasoning_details") || strings.Contains(string(convertedWire), "reasoning_content") {
		t.Fatalf("chat aliases leaked into Responses API wire: %s", convertedWire)
	}
}

func TestBuildNonStreamingResponseReasoningDetailsWire(t *testing.T) {
	chat := inresp.BuildNonStreamingResponse(
		"req-reasoning",
		"test-model",
		inresp.ExtractedMessage{Content: "answer", Reasoning: "full thought"},
		protocol.UsageInfo{PromptTokens: 2, CompletionTokens: 3},
		16,
		"",
		"",
	)

	wire, err := json.Marshal(chat)
	if err != nil {
		t.Fatalf("marshal reconstructed chat response: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(wire, &decoded); err != nil {
		t.Fatalf("unmarshal reconstructed chat response: %v", err)
	}
	message := decoded["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	if message["reasoning"] != "full thought" || message["reasoning_content"] != "full thought" {
		t.Fatalf("reconstructed reasoning aliases = %#v", message)
	}
	detail := message["reasoning_details"].([]any)[0].(map[string]any)
	if detail["type"] != "reasoning.text" || detail["text"] != "full thought" || detail["id"] != "reasoning-text-0" || detail["format"] != "unknown" || detail["index"] != float64(0) || detail["signature"] != nil {
		t.Fatalf("reconstructed reasoning detail = %#v", detail)
	}

	responsesWire, err := json.Marshal(inresp.ChatCompletionToResponses(chat, "test-model", "", ""))
	if err != nil {
		t.Fatalf("marshal converted Responses API result: %v", err)
	}
	if strings.Contains(string(responsesWire), "reasoning_details") || strings.Contains(string(responsesWire), "reasoning_content") {
		t.Fatalf("chat aliases leaked into Responses API wire: %s", responsesWire)
	}
}

func TestBuildNonStreamingResponsePreservesUpstreamReasoningDetails(t *testing.T) {
	msg := inresp.ExtractMessageWithReasoningPolicy([]string{
		`data: {"choices":[{"delta":{"reasoning":"legacy","reasoning_content":"canonical","reasoning_details":[{"type":"provider.custom","data":"first"}]}}]}`,
		`data: {"choices":[{"message":{"reasoning_content":"next","reasoning_details":[{"type":"reasoning.encrypted","data":"second"}]}}]}`,
	}, true)
	if msg.Reasoning != "canonicalnext" {
		t.Fatalf("reconstructed reasoning = %q, want reasoning_content precedence", msg.Reasoning)
	}
	chat := inresp.BuildNonStreamingResponse("req-upstream-details", "test-model", msg, protocol.UsageInfo{}, 16, "", "")
	wire, err := json.Marshal(chat)
	if err != nil {
		t.Fatalf("marshal reconstructed response: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(wire, &decoded); err != nil {
		t.Fatalf("decode reconstructed response: %v", err)
	}
	message := decoded["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
	details := message["reasoning_details"].([]any)
	if len(details) != 2 || details[0].(map[string]any)["type"] != "provider.custom" || details[1].(map[string]any)["type"] != "reasoning.encrypted" {
		t.Fatalf("upstream reasoning_details not preserved in order: %#v", details)
	}
	if details[0].(map[string]any)["data"] != "first" || details[1].(map[string]any)["data"] != "second" {
		t.Fatalf("upstream reasoning_details values changed: %#v", details)
	}
}

func TestExtractMessageReasoningDetailsNullPlaceholder(t *testing.T) {
	t.Run("later arrays supersede null and accumulate", func(t *testing.T) {
		msg := inresp.ExtractMessageWithReasoningPolicy([]string{
			`data: {"choices":[{"delta":{"reasoning":"a","reasoning_details":null}}]}`,
			`data: {"choices":[{"delta":{"reasoning":"b","reasoning_details":[{"type":"first"}]}}]}`,
			`data: {"choices":[{"delta":{"reasoning":"c","reasoning_details":[{"type":"second"}]}}]}`,
		}, true)
		details, ok := msg.ReasoningDetails.([]json.RawMessage)
		if !ok || len(details) != 2 {
			t.Fatalf("accumulated reasoning_details = %#v, want two array items", msg.ReasoningDetails)
		}
		var first, second map[string]any
		if err := json.Unmarshal(details[0], &first); err != nil {
			t.Fatalf("decode first reasoning detail: %v", err)
		}
		if err := json.Unmarshal(details[1], &second); err != nil {
			t.Fatalf("decode second reasoning detail: %v", err)
		}
		if first["type"] != "first" || second["type"] != "second" {
			t.Fatalf("reasoning detail order changed: %#v %#v", first, second)
		}
	})

	t.Run("lone null survives malformed later chunk", func(t *testing.T) {
		msg := inresp.ExtractMessage([]string{
			`data: {"choices":[{"delta":{"reasoning":"a","reasoning_details":null}}]}`,
			`data: {"choices":[{"delta":{"reasoning":"b","reasoning_details":[}}]}`,
		})
		raw, ok := msg.ReasoningDetails.(json.RawMessage)
		if !ok || string(raw) != "null" {
			t.Fatalf("lone null reasoning_details = %#v", msg.ReasoningDetails)
		}
		chat := inresp.BuildNonStreamingResponse("req-null", "test-model", msg, protocol.UsageInfo{}, 16, "", "")
		wire, err := json.Marshal(chat)
		if err != nil {
			t.Fatalf("marshal null reasoning_details: %v", err)
		}
		var decoded map[string]any
		if err := json.Unmarshal(wire, &decoded); err != nil {
			t.Fatalf("decode null reasoning_details response: %v", err)
		}
		message := decoded["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
		value, exists := message["reasoning_details"]
		if !exists || value != nil {
			t.Fatalf("null reasoning_details not preserved: %#v", message)
		}
	})
}

func TestExtractMessageReasoningPolicyByEndpoint(t *testing.T) {
	chunks := []string{`data: {"choices":[{"delta":{"content":"answer","reasoning":"legacy","reasoning_content":"canonical"}}]}`}
	responsesMessage := inresp.ExtractMessage(chunks)
	chatMessage := inresp.ExtractMessageWithReasoningPolicy(chunks, true)
	if responsesMessage.Reasoning != "legacy" {
		t.Fatalf("Responses fallback reasoning = %q, want historical reasoning alias", responsesMessage.Reasoning)
	}
	if chatMessage.Reasoning != "canonical" {
		t.Fatalf("chat fallback reasoning = %q, want reasoning_content", chatMessage.Reasoning)
	}

	responses := inresp.BuildResponsesResponse("req-policy", "test-model", responsesMessage, protocol.UsageInfo{}, 16, "", "")
	responsesWire, err := json.Marshal(responses)
	if err != nil {
		t.Fatalf("marshal Responses fallback: %v", err)
	}
	if strings.Contains(string(responsesWire), "reasoning_content") || strings.Contains(string(responsesWire), "reasoning_details") {
		t.Fatalf("chat fields leaked into Responses fallback: %s", responsesWire)
	}
	chat := inresp.BuildNonStreamingResponse("req-policy", "test-model", chatMessage, protocol.UsageInfo{}, 16, "", "")
	chatWire, err := json.Marshal(chat)
	if err != nil {
		t.Fatalf("marshal chat fallback: %v", err)
	}
	if !strings.Contains(string(chatWire), `"reasoning_content":"canonical"`) || !strings.Contains(string(chatWire), `"reasoning_details"`) {
		t.Fatalf("chat fallback missing canonical reasoning fields: %s", chatWire)
	}
}

func TestBuildNonStreamingResponsePreservesNonArrayReasoningDetails(t *testing.T) {
	for _, tt := range []struct {
		name string
		raw  string
	}{
		{name: "null", raw: `null`},
		{name: "object", raw: `{"type":"provider.custom","opaque":true}`},
		{name: "scalar", raw: `"encrypted-token"`},
	} {
		t.Run(tt.name, func(t *testing.T) {
			chunk := `data: {"choices":[{"delta":{"reasoning":"thought","reasoning_details":` + tt.raw + `}}]}`
			msg := inresp.ExtractMessage([]string{chunk})
			if !msg.ReasoningDetailsPresent {
				t.Fatal("reasoning_details key presence was lost")
			}
			chat := inresp.BuildNonStreamingResponse("req-non-array", "test-model", msg, protocol.UsageInfo{}, 16, "", "")
			wire, err := json.Marshal(chat)
			if err != nil {
				t.Fatalf("marshal reconstructed response: %v", err)
			}
			var decoded map[string]any
			if err := json.Unmarshal(wire, &decoded); err != nil {
				t.Fatalf("decode reconstructed response: %v", err)
			}
			message := decoded["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)
			value, ok := message["reasoning_details"]
			if !ok {
				t.Fatalf("reasoning_details missing from wire: %s", wire)
			}
			if tt.name == "object" {
				var want any
				if err := json.Unmarshal([]byte(tt.raw), &want); err != nil {
					t.Fatalf("decode expected reasoning_details: %v", err)
				}
				if !reflect.DeepEqual(value, want) {
					t.Fatalf("reasoning_details = %#v, want %#v", value, want)
				}
			} else {
				got, err := json.Marshal(value)
				if err != nil {
					t.Fatalf("marshal preserved reasoning_details: %v", err)
				}
				if string(got) != tt.raw {
					t.Fatalf("reasoning_details = %s, want %s", got, tt.raw)
				}
			}
		})
	}
}

func TestChatCompletionToResponses(t *testing.T) {
	chat := types.ChatCompletionResponse{
		ID:      "chatcmpl-test",
		Object:  "chat.completion",
		Created: 123,
		Model:   "local-path",
		Choices: []types.ChatCompletionChoice{{
			FinishReason: "tool_calls",
			Message: types.ChatCompletionMessage{
				Role:      "assistant",
				Content:   "",
				Reasoning: "need weather",
				ToolCalls: []map[string]any{
					{
						"id":   "call_123",
						"type": "function",
						"function": map[string]any{
							"name":      "get_current_weather",
							"arguments": `{"city":"Paris"}`,
						},
					},
				},
			},
		}},
		Usage: types.ChatCompletionUsage{
			PromptTokens:     10,
			CompletionTokens: 5,
			TotalTokens:      15,
		},
	}

	got := inresp.ChatCompletionToResponses(chat, "mlx-community/gemma-4-26b-a4b-it-8bit", "", "")
	if got.Object != "response" || got.Model != "mlx-community/gemma-4-26b-a4b-it-8bit" {
		t.Fatalf("response metadata = %#v", got)
	}
	output := got.Output
	if output[0].(map[string]any)["type"] != "reasoning" {
		t.Fatalf("first output = %#v", output[0])
	}
	call := output[1].(map[string]any)
	if call["type"] != "function_call" || call["call_id"] != "call_123" {
		t.Fatalf("function call output = %#v", call)
	}
	usage := got.Usage
	if usage.InputTokens != 10 || usage.OutputTokens != 5 {
		t.Fatalf("usage = %#v", usage)
	}

	// Verify wire format preserves zero-valued fields.
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	wire := string(b)
	if !strings.Contains(wire, `"incomplete_details"`) {
		t.Errorf("wire output missing incomplete_details field: %s", wire)
	}
	if !strings.Contains(wire, `"cached_tokens"`) {
		t.Errorf("wire output missing cached_tokens in usage details: %s", wire)
	}
	if !strings.Contains(wire, `"reasoning_tokens"`) {
		t.Errorf("wire output missing reasoning_tokens in usage details: %s", wire)
	}
}

func TestExtractMessageWithNullFields(t *testing.T) {
	// Simulates real vllm-mlx chunks where the first chunk has null content
	// and subsequent chunks have actual content.
	chunks := []string{
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}`,
		`data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}]}`,
	}

	msg := inresp.ExtractMessage(chunks)
	if msg.Content != "Hello world" {
		t.Errorf("content = %q, want %q", msg.Content, "Hello world")
	}
}

func TestExtractMessageWithReasoningContentAndThinkTags(t *testing.T) {
	chunks := []string{
		`data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}`,
		`data: {"choices":[{"delta":{"content":"<think>more hidden</think>\n\n4"}}]}`,
	}

	msg := inresp.ExtractMessage(chunks)
	if msg.Content != "4" {
		t.Fatalf("content = %q, want 4", msg.Content)
	}
	if !strings.Contains(msg.Reasoning, "hidden") || !strings.Contains(msg.Reasoning, "more hidden") {
		t.Fatalf("reasoning not preserved: %q", msg.Reasoning)
	}
}
