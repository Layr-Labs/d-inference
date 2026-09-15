package api

import (
	"encoding/json"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func assertReasoningItemFinished(t *testing.T, response types.ResponsesResponse) {
	t.Helper()
	if len(response.Output) == 0 {
		t.Fatal("missing original output")
	}
	item, ok := response.Output[0].(map[string]any)
	if !ok || item["type"] != "reasoning" || item["status"] != "completed" {
		t.Fatalf("final reasoning item is not explicitly completed: %#v", response.Output[0])
	}
	parts, ok := item["summary"].([]map[string]any)
	if !ok || len(parts) != 1 || parts[0]["text"] != "original reasoning" {
		t.Fatal("reasoning bytes changed")
	}
}

func TestResponsesReasoningItemCompletionStatus(t *testing.T) {
	for _, finish := range []string{"stop", "length"} {
		t.Run(finish, func(t *testing.T) {
			response := buildResponsesResponse("job", "model",
				extractedMessage{Content: "4", Reasoning: "original reasoning", FinishReason: finish},
				protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5}, 32, "signature", "hash")
			assertReasoningItemFinished(t, response)
			want := "completed"
			if finish == "length" {
				want = "incomplete"
			}
			if response.Status != want {
				t.Fatalf("root status = %s, want %s", response.Status, want)
			}
			if response.SESignature != "signature" || response.ResponseHash != "hash" {
				t.Fatal("attestation fields changed")
			}
			if response.Usage.InputTokens != 10 || response.Usage.OutputTokens != 5 || response.Usage.TotalTokens != 15 {
				t.Fatal("usage changed")
			}
		})
	}
}

func TestConvertedChatReasoningItemCompletionStatus(t *testing.T) {
	var chat types.ChatCompletionResponse
	err := json.Unmarshal([]byte(`{"id":"chatcmpl-job","object":"chat.completion","created":123,"model":"model","choices":[{"index":0,"message":{"role":"assistant","content":"4","reasoning":"original reasoning"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}`), &chat)
	if err != nil {
		t.Fatal(err)
	}
	response := chatCompletionToResponses(chat, "model", "signature", "hash")
	assertReasoningItemFinished(t, response)
	if response.Status != "completed" {
		t.Fatal("completed root changed")
	}
}
