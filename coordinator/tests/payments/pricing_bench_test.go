package payments_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/payments"
)

func BenchmarkCostWithMinimum(b *testing.B) {
	b.ReportAllocs()
	rates := production.DefaultRates()
	usage := production.Usage{PromptTokens: 1500, CompletionTokens: 800}

	b.ResetTimer()
	for range b.N {
		_ = rates.CostWithMinimum(usage)
	}
}

func BenchmarkCostWithCustomRatesAndCache(b *testing.B) {
	b.ReportAllocs()
	// Custom enterprise pricing: $0.05 input, $0.15 output, $0.01 cache read per 1M tokens
	rates := production.Rates{Input: 50_000, Output: 150_000, CacheRead: 10_000}
	usage := production.Usage{PromptTokens: 1500, CachedTokens: 1200, CompletionTokens: 800}

	b.ResetTimer()
	for range b.N {
		_ = rates.CostWithMinimum(usage)
	}
}
