package payments

import (
	"testing"
)

func BenchmarkCalculateCost(b *testing.B) {
	b.ReportAllocs()
	// Known model with explicit pricing
	model := "mlx-community/Qwen3.5-122B-A10B-8bit"
	promptTokens := 1500
	completionTokens := 800

	b.ResetTimer()
	for range b.N {
		_ = CalculateCost(model, promptTokens, completionTokens)
	}
}

func BenchmarkCalculateCostWithOverrides(b *testing.B) {
	b.ReportAllocs()
	model := "mlx-community/Qwen3.5-122B-A10B-8bit"
	promptTokens := 1500
	completionTokens := 800
	// Custom enterprise pricing: $0.05 input, $0.15 output per 1M tokens
	customInput := int64(50_000)
	customOutput := int64(150_000)

	b.ResetTimer()
	for range b.N {
		_ = CalculateCostWithOverrides(model, promptTokens, completionTokens, customInput, customOutput, true)
	}
}
