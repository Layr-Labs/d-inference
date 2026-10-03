package response

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestUsageChunkParseAndFinalize covers the parse-once + finalize helpers.
func TestUsageChunkParseAndFinalize(t *testing.T) {
	usageChunk := `data: {"object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`
	pr := &registry.PendingRequest{Model: "gpt-oss-20b"}

	obj, ok := parseUsageOnlyStreamChunk(usageChunk)
	if !ok {
		t.Fatal("expected the usage-only chunk to be detected + parsed")
	}
	out := FinalizeUsageChunk(obj, protocol.UsageInfo{CompletionTokens: 50, ReasoningTokens: 8}, pr)
	if !strings.Contains(out, `"reasoning_tokens":8`) {
		t.Fatalf("expected reasoning_tokens spliced into usage; got %s", out)
	}

	// A content delta and a usage:null chunk are NOT usage-only chunks.
	if _, ok := parseUsageOnlyStreamChunk(`data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"x"}}]}`); ok {
		t.Fatal("a content delta must NOT be treated as a usage-only chunk")
	}
	if _, ok := parseUsageOnlyStreamChunk(`data: {"object":"chat.completion.chunk","choices":[],"usage":null}`); ok {
		t.Fatal("a usage:null chunk must NOT be treated as a usage-only chunk")
	}

	// No reasoning → no completion_tokens_details added.
	obj2, _ := parseUsageOnlyStreamChunk(usageChunk)
	if plain := FinalizeUsageChunk(obj2, protocol.UsageInfo{CompletionTokens: 50}, pr); strings.Contains(plain, "completion_tokens_details") {
		t.Fatalf("expected no reasoning detail when ReasoningTokens=0; got %s", plain)
	}

	// Build id rewritten to the public alias.
	obj3, _ := parseUsageOnlyStreamChunk(usageChunk)
	prAlias := &registry.PendingRequest{Model: "gpt-oss-20b", PublicModel: "gpt-oss"}
	aliased := FinalizeUsageChunk(obj3, protocol.UsageInfo{CompletionTokens: 50, ReasoningTokens: 8}, prAlias)
	if !strings.Contains(aliased, `"model":"gpt-oss"`) || strings.Contains(aliased, `"model":"gpt-oss-20b"`) {
		t.Fatalf("expected build id rewritten to the public alias; got %s", aliased)
	}
}
