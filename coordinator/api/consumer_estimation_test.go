package api

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestApproximateTokenCount verifies the len/4 routing heuristic.
func TestApproximateTokenCount(t *testing.T) {
	tests := []struct {
		name  string
		input any
		want  int
	}{
		{"nil", nil, 0},
		{"empty string", "", 0},
		{"single char", "a", 1},
		{"short ASCII", "hello", 1},                        // 5/4 = 1
		{"english prose", "The quick brown fox jumps.", 6}, // 26/4 = 6
		{"16 bytes", "0123456789abcdef", 4},                // 16/4 = 4
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := approximateTokenCount(tt.input)
			if got != tt.want {
				t.Errorf("approximateTokenCount(%v) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

// TestApproximateTokenCountUpperBound verifies that the billing upper bound
// returns len(text) — guaranteed >= actual BPE tokens for any tokenizer.
func TestApproximateTokenCountUpperBound(t *testing.T) {
	tests := []struct {
		name  string
		input any
		want  int
	}{
		{"nil", nil, 0},
		{"empty string", "", 0},
		{"single char", "a", 1},
		{"short ASCII", "hello", 5},
		{"english prose", "The quick brown fox jumps over the lazy dog.", 44},
		{"code snippet", "func main() { fmt.Println(\"hello\") }", 36},
		{"multibyte UTF-8", "こんにちは世界", 21}, // 7 chars × 3 bytes each
		{"emoji", "👋🌍", 8},                 // 2 emoji × 4 bytes each
		{"chat template tags", "<|im_start|>system\nYou are helpful.<|im_end|>", 45},
		{"json object", map[string]string{"role": "user", "content": "hi"}, len(`{"content":"hi","role":"user"}`)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := approximateTokenCountUpperBound(tt.input)
			if got != tt.want {
				t.Errorf("approximateTokenCountUpperBound(%v) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

// TestBillingEstimateAlwaysGERoutingEstimate confirms that the billing
// upper bound is always >= the routing heuristic for the same input.
func TestBillingEstimateAlwaysGERoutingEstimate(t *testing.T) {
	inputs := []string{
		"Hello, world!",
		"def fibonacci(n):\n    if n <= 1:\n        return n\n    return fibonacci(n-1) + fibonacci(n-2)",
		"SELECT u.id, u.name FROM users u WHERE u.active = true ORDER BY u.created_at DESC LIMIT 10;",
		"これはテストです。日本語のテキストはトークン数が多くなります。",
		strings.Repeat("a", 1000),
	}
	for _, input := range inputs {
		routing := approximateTokenCount(input)
		billing := approximateTokenCountUpperBound(input)
		if billing < routing {
			t.Errorf("billing(%d) < routing(%d) for %q", billing, routing, input[:min(20, len(input))])
		}
	}
}

// TestEstimatePromptTokens verifies the routing estimate for different
// request field layouts.
func TestEstimatePromptTokens(t *testing.T) {
	tests := []struct {
		name  string
		input map[string]any
		want  int
	}{
		{
			name:  "messages field",
			input: map[string]any{"messages": []any{map[string]any{"role": "user", "content": "hello"}}},
			want:  5, // 4 framing + 5/4 text tokens.
		},
		{
			name:  "prompt field",
			input: map[string]any{"prompt": "Tell me a story"},
			want:  3,
		},
		{
			name:  "input field",
			input: map[string]any{"input": "Translate this"},
			want:  3,
		},
		{
			name: "responses structured input",
			input: map[string]any{"input": []any{map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "input_text", "text": "hello"},
			}}}},
			want: 5, // 4 framing + 5/4 text tokens; do not count JSON wrapper bytes.
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			routing := estimatePromptTokens(tt.input)
			billing := estimateBillingPromptTokens(tt.input)
			if routing != tt.want {
				t.Errorf("estimatePromptTokens() = %d, want %d", routing, tt.want)
			}
			if billing < routing {
				t.Errorf("billing(%d) < routing(%d)", billing, routing)
			}
		})
	}
}

// TestResolveReasoningTokens covers the precedence between the provider's
// tokenizer-accurate count and the legacy completion-tokens fallback.
func TestResolveReasoningTokens(t *testing.T) {
	cases := []struct {
		name      string
		usage     protocol.UsageInfo
		reasoning string
		want      uint64
	}{
		{
			name:      "accurate count preferred",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 42},
			reasoning: "thinking...",
			want:      42,
		},
		{
			name:      "fallback to completion tokens for legacy provider",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 0},
			reasoning: "thinking...",
			want:      100,
		},
		{
			name:      "no reasoning content yields zero",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 0},
			reasoning: "",
			want:      0,
		},
		{
			name:      "accurate count wins even without reasoning text",
			usage:     protocol.UsageInfo{CompletionTokens: 100, ReasoningTokens: 7},
			reasoning: "",
			want:      7,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolveReasoningTokens(tc.usage, tc.reasoning); got != tc.want {
				t.Errorf("resolveReasoningTokens = %d, want %d", got, tc.want)
			}
		})
	}
}

// TestBuildNonStreamingResponseReasoningDetails verifies the chat
// completion usage object carries completion_tokens_details.reasoning_tokens
// only when there is a reasoning count to report.
func TestBuildNonStreamingResponseReasoningDetails(t *testing.T) {
	msg := extractedMessage{Content: "4", Reasoning: "2+2"}
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20, ReasoningTokens: 8}

	resp := buildNonStreamingResponse("req-1", "gpt-oss-20b", msg, usage, 0, "", "")
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
	plain := buildNonStreamingResponse("req-2", "gpt-oss-20b",
		extractedMessage{Content: "hi"},
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
	msg := extractedMessage{Content: "4", Reasoning: "2+2"}
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20, ReasoningTokens: 8}

	resp := buildResponsesResponse("req-1", "gpt-oss-20b", msg, usage, 0, "", "")
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
	injectReasoningDetailIntoRawUsage(obj, protocol.UsageInfo{CompletionTokens: 30, ReasoningTokens: 12})
	details := obj["usage"].(map[string]any)["completion_tokens_details"].(map[string]any)
	if details["reasoning_tokens"] != 12 {
		t.Errorf("reasoning_tokens = %v, want 12", details["reasoning_tokens"])
	}

	// No-op when the provider reported no reasoning count.
	plain := map[string]any{"usage": map[string]any{"completion_tokens": float64(5)}}
	injectReasoningDetailIntoRawUsage(plain, protocol.UsageInfo{CompletionTokens: 5, ReasoningTokens: 0})
	if _, ok := plain["usage"].(map[string]any)["completion_tokens_details"]; ok {
		t.Errorf("expected no details injected for zero reasoning count")
	}

	// Never overrides an existing detail.
	existing := map[string]any{
		"usage": map[string]any{
			"completion_tokens_details": map[string]any{"reasoning_tokens": float64(99)},
		},
	}
	injectReasoningDetailIntoRawUsage(existing, protocol.UsageInfo{ReasoningTokens: 5})
	got := existing["usage"].(map[string]any)["completion_tokens_details"].(map[string]any)["reasoning_tokens"]
	if got != float64(99) {
		t.Errorf("reasoning_tokens = %v, want 99 (must not override)", got)
	}

	// No-op when there is no usage object at all.
	noUsage := map[string]any{"object": "chat.completion"}
	injectReasoningDetailIntoRawUsage(noUsage, protocol.UsageInfo{ReasoningTokens: 7})
	if _, ok := noUsage["usage"]; ok {
		t.Errorf("did not expect a usage object to be created")
	}
}

// TestDetectMediaRequirementAndTokenEstimate verifies media detection and that
// the media-aware estimator counts an image as a flat cost rather than its
// inflated base64 length (which would distort routing admission and billing).
func TestDetectMediaRequirementAndTokenEstimate(t *testing.T) {
	bigImage := "data:image/png;base64," + strings.Repeat("A", 200_000)
	parsed := map[string]any{
		"messages": []any{
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "text", "text": "what is in this image?"},
				map[string]any{"type": "image_url", "image_url": map[string]any{"url": bigImage}},
			}},
		},
	}
	if !detectMediaRequirement(parsed) {
		t.Fatal("expected media requirement detected for an image_url content part")
	}
	got := estimatePromptTokens(parsed)
	if got > 1000 {
		t.Fatalf("media-aware ROUTING estimate must ignore base64 length; got %d tokens for a 200KB image", got)
	}
	if got < imagePromptTokenCost {
		t.Fatalf("routing estimate should include the flat per-image cost (%d); got %d", imagePromptTokenCost, got)
	}
	// Billing intentionally stays a guaranteed UPPER bound (still counts the
	// base64 bytes) so it can never under-reserve; over-reservation is refunded
	// after inference. It must therefore exceed the small routing estimate here.
	if b := estimateBillingPromptTokens(parsed); b <= got {
		t.Fatalf("billing upper bound (%d) should exceed the routing estimate (%d) for a base64 image", b, got)
	}

	textParsed := map[string]any{
		"messages": []any{
			map[string]any{"role": "user", "content": "hello world"},
		},
	}
	if detectMediaRequirement(textParsed) {
		t.Fatal("a text-only request must not be flagged as requiring vision")
	}
}

// TestDetectMediaRequirementResponsesInput verifies the Responses API surface
// (input[].content parts) is gated too, so a media request there fails fast
// rather than being silently routed text-blind.
func TestDetectMediaRequirementResponsesInput(t *testing.T) {
	bigImage := "data:image/png;base64," + strings.Repeat("A", 200_000)
	withImage := map[string]any{
		"input": []any{
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "input_text", "text": "describe"},
				map[string]any{"type": "input_image", "image_url": bigImage},
			}},
		},
	}
	if !detectMediaRequirement(withImage) {
		t.Fatal("expected media detected in Responses API input parts")
	}
	got := estimatePromptTokens(withImage)
	if got > 1000 {
		t.Fatalf("Responses input estimate must ignore base64 length; got %d tokens for a 200KB image", got)
	}
	if got < imagePromptTokenCost {
		t.Fatalf("Responses input estimate should include flat image cost (%d); got %d", imagePromptTokenCost, got)
	}
	textOnly := map[string]any{"input": "just a string prompt"}
	if detectMediaRequirement(textOnly) {
		t.Fatal("a string Responses input must not be flagged as media")
	}
}

// TestDetectMediaRequirementAnthropicImageBlock verifies Anthropic /v1/messages
// image content blocks ({"type":"image","source":...}) are detected for the
// vision routing gate, not just OpenAI-style image_url parts.
func TestDetectMediaRequirementAnthropicImageBlock(t *testing.T) {
	parsed := map[string]any{
		"messages": []any{
			map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "text", "text": "what is this?"},
				map[string]any{"type": "image", "source": map[string]any{
					"type": "base64", "media_type": "image/png", "data": "AAAA",
				}},
			}},
		},
	}
	if !detectMediaRequirement(parsed) {
		t.Fatal("expected Anthropic image content block to be detected as media")
	}
}

// TestBodyForProviderPenaltyGating verifies the coordinator strips the penalty
// fields that crash the pre-fix VLM path, but ONLY for vision requests routed to
// a provider below penaltySafeProviderVersion. Fixed providers and text requests
// keep their penalties. See bodyForProvider.
func TestBodyForProviderPenaltyGating(t *testing.T) {
	visionBody := []byte(`{"model":"gemma-4-26b","temperature":1.0,"precision_probe":9007199254740993,"repetition_penalty":1.0,` +
		`"presence_penalty":0.0,"frequency_penalty":0.0,"messages":[{"role":"user","content":[` +
		`{"type":"text","text":"what is this?"},` +
		`{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}`)
	textBody := []byte(`{"model":"gemma-4-26b","repetition_penalty":1.3,` +
		`"messages":[{"role":"user","content":"hello"}]}`)

	has := func(body []byte, key string) bool {
		var m map[string]any
		if err := json.Unmarshal(body, &m); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		_, ok := m[key]
		return ok
	}
	penalties := []string{"repetition_penalty", "presence_penalty", "frequency_penalty"}

	// Vision + pre-fix provider → penalties stripped, other fields kept.
	out := bodyForProvider(visionBody, true, &registry.Provider{Version: "0.6.6"})
	for _, k := range penalties {
		if has(out, k) {
			t.Fatalf("pre-fix vision provider: expected %q stripped", k)
		}
	}
	if !has(out, "temperature") || !has(out, "messages") {
		t.Fatal("pre-fix vision provider: non-penalty fields must be preserved")
	}
	if !bytes.Contains(out, []byte("9007199254740993")) {
		t.Fatalf("pre-fix vision provider: field stripping rounded an exact numeric literal: %s", out)
	}

	// Vision + provider with unknown version → stripped (conservative).
	if has(bodyForProvider(visionBody, true, &registry.Provider{Version: ""}), "repetition_penalty") {
		t.Fatal("unknown-version vision provider: expected penalties stripped")
	}

	// Vision + fixed provider (== and > floor) → penalties preserved.
	for _, v := range []string{"0.6.7", "0.7.0"} {
		if !has(bodyForProvider(visionBody, true, &registry.Provider{Version: v}), "repetition_penalty") {
			t.Fatalf("fixed provider %s: penalties must pass through", v)
		}
	}

	// Text request (any provider) → penalties preserved.
	if !has(bodyForProvider(textBody, false, &registry.Provider{Version: "0.6.6"}), "repetition_penalty") {
		t.Fatal("text request: penalties must pass through")
	}

	// Vision + pre-fix provider but no penalty fields → returns rawBody unchanged.
	clean := []byte(`{"model":"gemma-4-26b","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}`)
	if out := bodyForProvider(clean, true, &registry.Provider{Version: "0.6.6"}); string(out) != string(clean) {
		t.Fatal("no-penalty vision body should be returned unchanged")
	}
}
