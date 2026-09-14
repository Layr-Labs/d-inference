package api

import (
	"strings"
	"testing"
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
