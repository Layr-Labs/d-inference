package request_test

import (
	"strings"
	"testing"

	estimate "github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
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
			got := estimate.ApproximateTokenCount(tt.input)
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
			got := estimate.ApproximateTokenCountUpperBound(tt.input)
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
		routing := estimate.ApproximateTokenCount(input)
		billing := estimate.ApproximateTokenCountUpperBound(input)
		if billing < routing {
			t.Errorf("billing(%d) < routing(%d) for %q", billing, routing, input[:min(20, len(input))])
		}
	}
}
