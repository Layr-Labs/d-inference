package response_test

import (
	"encoding/json"
	"strings"
	"testing"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestBuildNonStreamingResponseReasoningDetails verifies the chat
// completion usage object carries completion_tokens_details.reasoning_tokens
// only when there is a reasoning count to report.
func TestBuildNonStreamingResponseReasoningDetails(t *testing.T) {
	msg := inresp.ExtractedMessage{Content: "4", Reasoning: "2+2"}
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20, ReasoningTokens: 8}

	resp := inresp.BuildNonStreamingResponse("req-1", "gpt-oss-20b", msg, usage, 0, "", "")
	if resp.Usage.CompletionTokensDetails == nil {
		t.Fatalf("expected completion_tokens_details, got nil")
	}
	if resp.Usage.CompletionTokensDetails.ReasoningTokens != 8 {
		t.Errorf("reasoning_tokens = %d, want 8", resp.Usage.CompletionTokensDetails.ReasoningTokens)
	}

	// Wire format must include the nested detail.
	b, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(b), `"completion_tokens_details":{"reasoning_tokens":8}`) {
		t.Errorf("wire missing reasoning detail: %s", b)
	}

	// No reasoning content => no details object (omitempty).
	plain := inresp.BuildNonStreamingResponse("req-2", "gpt-oss-20b",
		inresp.ExtractedMessage{Content: "hi"},
		protocol.UsageInfo{PromptTokens: 3, CompletionTokens: 1}, 0, "", "")
	if plain.Usage.CompletionTokensDetails != nil {
		t.Errorf("expected no details for non-reasoning response, got %#v", plain.Usage.CompletionTokensDetails)
	}
	pb, _ := json.Marshal(plain)
	if strings.Contains(string(pb), "completion_tokens_details") {
		t.Errorf("non-reasoning wire should omit details: %s", pb)
	}
}

// TestBuildResponsesResponseReasoningTokens verifies the Responses API
// uses the accurate count when the provider supplies it.
func TestBuildResponsesResponseReasoningTokens(t *testing.T) {
	msg := inresp.ExtractedMessage{Content: "4", Reasoning: "2+2"}
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20, ReasoningTokens: 8}

	resp := inresp.BuildResponsesResponse("req-1", "gpt-oss-20b", msg, usage, 0, "", "")
	if resp.Usage.OutputTokensDetail.ReasoningTokens != 8 {
		t.Errorf("reasoning_tokens = %d, want 8 (accurate count, not %d completion)",
			resp.Usage.OutputTokensDetail.ReasoningTokens, usage.CompletionTokens)
	}
}

// TestInjectReasoningDetailIntoRawUsage covers the passthrough path: a
// provider-reported accurate reasoning count is spliced into the raw
// chat.completion usage object, without overriding an existing value.
func TestInjectReasoningDetailIntoRawUsage(t *testing.T) {
	// Adds detail when absent.
	obj := map[string]any{
		"object": "chat.completion",
		"usage": map[string]any{
			"prompt_tokens":     float64(10),
			"completion_tokens": float64(30),
		},
	}
	inresp.InjectReasoningDetailIntoRawUsage(obj, protocol.UsageInfo{CompletionTokens: 30, ReasoningTokens: 12})
	details := obj["usage"].(map[string]any)["completion_tokens_details"].(map[string]any)
	if details["reasoning_tokens"] != 12 {
		t.Errorf("reasoning_tokens = %v, want 12", details["reasoning_tokens"])
	}

	// No-op when the provider reported no reasoning count.
	plain := map[string]any{"usage": map[string]any{"completion_tokens": float64(5)}}
	inresp.InjectReasoningDetailIntoRawUsage(plain, protocol.UsageInfo{CompletionTokens: 5, ReasoningTokens: 0})
	if _, ok := plain["usage"].(map[string]any)["completion_tokens_details"]; ok {
		t.Errorf("expected no details injected for zero reasoning count")
	}

	// Never overrides an existing detail.
	existing := map[string]any{
		"usage": map[string]any{
			"completion_tokens_details": map[string]any{"reasoning_tokens": float64(99)},
		},
	}
	inresp.InjectReasoningDetailIntoRawUsage(existing, protocol.UsageInfo{ReasoningTokens: 5})
	got := existing["usage"].(map[string]any)["completion_tokens_details"].(map[string]any)["reasoning_tokens"]
	if got != float64(99) {
		t.Errorf("reasoning_tokens = %v, want 99 (must not override)", got)
	}

	// No-op when there is no usage object at all.
	noUsage := map[string]any{"object": "chat.completion"}
	inresp.InjectReasoningDetailIntoRawUsage(noUsage, protocol.UsageInfo{ReasoningTokens: 7})
	if _, ok := noUsage["usage"]; ok {
		t.Errorf("did not expect a usage object to be created")
	}
}
