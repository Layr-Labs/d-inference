package response

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"strings"
	"testing"
)

// TestUsageChunkParseAndFinalize covers the parse-once + finalize helpers.
func TestUsageChunkParseAndFinalize(t *testing.T) {
	usageChunk := `data: {"object":"chat.completion.chunk","model":"gpt-oss-20b","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":50,"total_tokens":60}}`
	pr := &registry.PendingRequest{Model: "gpt-oss-20b"}

	obj, ok := parseUsageOnlyStreamChunk(usageChunk)
	if !ok {
		t.Fatal("expected the usage-only chunk to be detected + parsed")
	}
	out := finalizeUsageChunk(obj, protocol.UsageInfo{CompletionTokens: 50, ReasoningTokens: 8}, pr)
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
	if plain := finalizeUsageChunk(obj2, protocol.UsageInfo{CompletionTokens: 50}, pr); strings.Contains(plain, "completion_tokens_details") {
		t.Fatalf("expected no reasoning detail when ReasoningTokens=0; got %s", plain)
	}

	// Build id rewritten to the public alias.
	obj3, _ := parseUsageOnlyStreamChunk(usageChunk)
	prAlias := &registry.PendingRequest{Model: "gpt-oss-20b", PublicModel: "gpt-oss"}
	aliased := finalizeUsageChunk(obj3, protocol.UsageInfo{CompletionTokens: 50, ReasoningTokens: 8}, prAlias)
	if !strings.Contains(aliased, `"model":"gpt-oss"`) || strings.Contains(aliased, `"model":"gpt-oss-20b"`) {
		t.Fatalf("expected build id rewritten to the public alias; got %s", aliased)
	}
}

func TestSanitizeNestedResponsesStreamCacheDetails(t *testing.T) {
	chunk := "event: response.completed\n" +
		"id: response-7\n" +
		": retain this comment\n" +
		`data: {"type":"response.completed","response":{"usage":{` + "\n" +
		`data: "input_tokens_details":{"cached\u005ftokens":99,"audio_tokens":7}}}}` + "\n\n"
	got := sanitizeStreamCacheDetails(chunk)
	if strings.Contains(got, `"cached_tokens"`) || strings.Contains(got, `cached\u005ftokens`) || strings.Contains(got, "99") {
		t.Fatalf("nested Responses cached_tokens survived: %s", got)
	}
	if !strings.Contains(got, `"audio_tokens":7`) || !strings.Contains(got, "event: response.completed") ||
		!strings.Contains(got, "id: response-7") || !strings.Contains(got, ": retain this comment") || strings.Count(got, "data:") != 1 {
		t.Fatalf("nested Responses sanitization removed unrelated content: %s", got)
	}
}

func TestSanitizeSplitMultilineChatStreamCacheDetails(t *testing.T) {
	for _, tc := range []struct {
		name    string
		choices string
	}{
		{name: "content", choices: `[{"delta":{"content":"hi"},"finish_reason":null}]`},
		{name: "finish", choices: `[{"delta":{},"finish_reason":"stop"}]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			chunk := "event: message\n" +
				"id: chat-9\n" +
				": keepalive\n" +
				`data: {"object":"chat.completion.chunk","choices":` + tc.choices + `,` + "\n" +
				`data: "usage":{"prompt_tokens_details":{"cached\u005ftokens":123,"audio_tokens":6}}}` + "\n\n"
			got := sanitizeStreamCacheDetails(chunk)
			if strings.Contains(got, "123") || strings.Contains(got, `cached\u005ftokens`) || strings.Contains(got, `"cached_tokens"`) {
				t.Fatalf("split %s frame retained cached_tokens: %s", tc.name, got)
			}
			for _, preserved := range []string{`"audio_tokens":6`, "event: message", "id: chat-9", ": keepalive"} {
				if !strings.Contains(got, preserved) {
					t.Fatalf("split %s frame lost %q: %s", tc.name, preserved, got)
				}
			}
			if strings.Count(got, "data:") != 1 || !strings.HasSuffix(got, "\n\n") {
				t.Fatalf("split %s frame was not re-emitted as one data line/event: %q", tc.name, got)
			}
		})
	}
}
