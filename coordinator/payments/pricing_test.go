package payments

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func int64Ptr(v int64) *int64 { return &v }

func TestDefaultRates(t *testing.T) {
	// Without DB-configured prices, every model gets the fallback defaults and a
	// cache-read rate derived from the default input price.
	got := DefaultRates()
	want := Rates{
		Input:     DefaultInputPricePerMillion,
		Output:    DefaultOutputPricePerMillion,
		CacheRead: DefaultCacheReadPrice(DefaultInputPricePerMillion),
	}
	if got != want {
		t.Fatalf("DefaultRates() = %+v, want %+v", got, want)
	}
	if got.CacheRead != 25_000 {
		t.Fatalf("default cache read = %d, want 25000 (50%% of $0.05)", got.CacheRead)
	}
	if RatesFor(store.ModelPrice{InputPrice: 1, OutputPrice: 2}, false) != want {
		t.Fatal("an unconfigured lookup must ignore the zero row and use the defaults")
	}
}

func TestRatesForDerivesCacheReadFromInputWhenUnset(t *testing.T) {
	got := RatesFor(store.ModelPrice{InputPrice: 300_000, OutputPrice: 1_200_000}, true)
	want := Rates{Input: 300_000, Output: 1_200_000, CacheRead: 150_000}
	if got != want {
		t.Fatalf("derived rates = %+v, want %+v", got, want)
	}
}

func TestRatesForHonorsExplicitCacheRead(t *testing.T) {
	for _, explicit := range []int64{0, 1, 30_000, 300_000} {
		got := RatesFor(store.ModelPrice{InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: int64Ptr(explicit)}, true)
		if got.CacheRead != explicit {
			t.Errorf("explicit cache_read_price %d resolved to %d", explicit, got.CacheRead)
		}
	}
}

func TestDefaultCacheReadPriceFloorsToWholeMicroUSD(t *testing.T) {
	if got := DefaultCacheReadPrice(1); got != 0 {
		t.Errorf("DefaultCacheReadPrice(1) = %d, want 0 (integer arithmetic floors)", got)
	}
	if got := DefaultCacheReadPrice(50_001); got != 25_000 {
		t.Errorf("DefaultCacheReadPrice(50001) = %d, want 25000", got)
	}
}

func TestCostWithMinimum(t *testing.T) {
	// All cases use the fallback rates ($0.05 input, $0.025 cache read, $0.20
	// output per 1M tokens).
	rates := DefaultRates()
	tests := []struct {
		name  string
		usage Usage
		want  int64
	}{
		{"1M output tokens", Usage{CompletionTokens: 1_000_000}, 200_000},
		{"1M input + 1M output", Usage{PromptTokens: 1_000_000, CompletionTokens: 1_000_000}, 250_000},
		{"only input tokens", Usage{PromptTokens: 1_000_000}, 50_000},
		{"half the prompt cached bills half at the cache-read rate", Usage{PromptTokens: 1_000_000, CachedTokens: 500_000}, 25_000 + 12_500},
		{"fully cached prompt", Usage{PromptTokens: 1_000_000, CachedTokens: 1_000_000}, 25_000},
		{"small request hits minimum", Usage{PromptTokens: 10, CompletionTokens: 10}, 100},
		{"zero tokens hits minimum", Usage{}, 100},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := rates.CostWithMinimum(tc.usage); got != tc.want {
				t.Errorf("CostWithMinimum(%+v) = %d, want %d", tc.usage, got, tc.want)
			}
		})
	}
}

func TestCostWithCustomRates(t *testing.T) {
	rates := Rates{Input: 15_000, Output: 70_000, CacheRead: 3_000}
	tests := []struct {
		name  string
		usage Usage
		want  int64
	}{
		{"custom rates, no cache", Usage{PromptTokens: 1_000_000, CompletionTokens: 1_000_000}, 85_000},
		{"custom rates, cached prefix", Usage{PromptTokens: 1_000_000, CachedTokens: 800_000, CompletionTokens: 1_000_000}, 200_000*15_000/1_000_000 + 800_000*3_000/1_000_000 + 70_000},
		{"tiny request floors to the minimum", Usage{PromptTokens: 10, CompletionTokens: 10}, 100},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := rates.CostWithMinimum(tc.usage); got != tc.want {
				t.Errorf("CostWithMinimum(%+v) = %d, want %d", tc.usage, got, tc.want)
			}
		})
	}
}

// A cache hit can only ever lower the bill relative to the same prompt served
// cold, and never below the rate the cache-read price implies.
func TestCachedTokensNeverIncreaseCost(t *testing.T) {
	rates := Rates{Input: 500_000, Output: 2_000_000, CacheRead: 100_000}
	cold := rates.Cost(Usage{PromptTokens: 40_000, CompletionTokens: 1_000})
	for cached := 0; cached <= 40_000; cached += 5_000 {
		warm := rates.Cost(Usage{PromptTokens: 40_000, CachedTokens: cached, CompletionTokens: 1_000})
		if warm > cold {
			t.Fatalf("cached=%d cost %d exceeds cold cost %d", cached, warm, cold)
		}
		want := int64(40_000-cached)*500_000/1_000_000 + int64(cached)*100_000/1_000_000 + 1_000*2_000_000/1_000_000
		if warm != want {
			t.Fatalf("cached=%d cost %d, want %d", cached, warm, want)
		}
	}
}

// Malformed usage must not produce a negative charge or bill more tokens than
// were in the prompt: cached tokens are clamped to the prompt and negative
// counts bill as zero.
func TestCostClampsMalformedUsage(t *testing.T) {
	rates := Rates{Input: 1_000_000, Output: 1_000_000, CacheRead: 0}
	// More cached than prompt tokens: the whole prompt is cached, nothing more.
	if got := rates.Cost(Usage{PromptTokens: 100, CachedTokens: 1_000, CompletionTokens: 100}); got != 100 {
		t.Errorf("over-reported cache cost = %d, want 100 (completion only)", got)
	}
	// Negative counts never turn into credits.
	if got := rates.Cost(Usage{PromptTokens: -100, CachedTokens: -5, CompletionTokens: -100}); got != 0 {
		t.Errorf("negative usage cost = %d, want 0", got)
	}
	if got := rates.CostWithMinimum(Usage{PromptTokens: -100}); got != MinimumCharge() {
		t.Errorf("negative usage with minimum = %d, want %d", got, MinimumCharge())
	}
}

// Provider-reported counts are untrusted: an absurd count must saturate, never
// wrap into a negative cost that the settlement path would refund.
func TestCostSaturatesInsteadOfOverflowing(t *testing.T) {
	rates := DefaultRates()
	for _, u := range []Usage{
		{PromptTokens: 1 << 48},
		{CompletionTokens: 1 << 48},
		{PromptTokens: 1 << 62, CachedTokens: 1 << 62},
		{PromptTokens: math.MaxInt, CompletionTokens: math.MaxInt},
	} {
		got := rates.Cost(u)
		if got < 0 {
			t.Fatalf("Cost(%+v) = %d, negative", u, got)
		}
		// The exact value is irrelevant: it only has to be huge and positive so
		// the overage clamp in settlement takes over.
		if got < 1<<40 {
			t.Fatalf("Cost(%+v) = %d, expected a saturated (huge) charge", u, got)
		}
		if rates.CostWithMinimum(u) != got {
			t.Fatalf("CostWithMinimum(%+v) disagrees with Cost", u)
		}
	}
	// Absurd rates from a corrupt row saturate the same way.
	huge := Rates{Input: math.MaxInt64, Output: math.MaxInt64, CacheRead: math.MaxInt64}
	if got := huge.Cost(Usage{PromptTokens: 1 << 40, CompletionTokens: 1 << 40}); got != math.MaxInt64 {
		t.Fatalf("saturated cost = %d, want MaxInt64", got)
	}
	// Negative rates (corrupt row) bill as zero, not as credits.
	neg := Rates{Input: -1, Output: -1, CacheRead: -1}
	if got := neg.Cost(Usage{PromptTokens: 1_000, CompletionTokens: 1_000}); got != 1 {
		t.Fatalf("negative-rate cost = %d, want 1 (nonzero usage floor)", got)
	}
}

func TestTermCost(t *testing.T) {
	if got := termCost(1_000_000, 300_000); got != 300_000 {
		t.Errorf("1M tokens at 300000 = %d", got)
	}
	if got := termCost(3, 500_000); got != 1 {
		t.Errorf("3 × 0.5 floors to %d, want 1", got)
	}
	if got := termCost(0, 500_000); got != 0 {
		t.Errorf("zero tokens = %d", got)
	}
	if got := termCost(-5, 500_000); got != 0 {
		t.Errorf("negative tokens = %d", got)
	}
	// Just below and above the 64-bit product boundary.
	if got := termCost(1<<32, 1<<31); got != (1<<63)/1_000_000 {
		t.Errorf("2^63 product = %d, want %d", got, (1<<63)/1_000_000)
	}
	// 2^80 overflows the product but its quotient (÷1e6 ≈ 1.2e18) fits.
	if got := termCost(1<<40, 1<<40); got != int64(1208925819614629174) {
		t.Errorf("2^80 product = %d, want 1208925819614629174", got)
	}
	// 2^83: the 128-bit quotient still fits in uint64 but not in int64.
	if got := termCost(1<<43, 1<<40); got != math.MaxInt64 {
		t.Errorf("2^83 product = %d, want MaxInt64", got)
	}
	// 2^100: the quotient itself exceeds 64 bits.
	if got := termCost(1<<50, 1<<50); got != math.MaxInt64 {
		t.Errorf("2^100 product = %d, want MaxInt64", got)
	}
}

// Each term floors independently, so the settled cost is never above the
// exact per-token math and at most 3 µUSD below it — the direction OpenRouter
// would observe when it recomputes the cost from the usage and the feed.
func TestCostFloorsEachTermTowardsZero(t *testing.T) {
	rates := Rates{Input: 333_333, Output: 777_777, CacheRead: 111_111}
	u := Usage{PromptTokens: 12_345, CachedTokens: 6_789, CompletionTokens: 987}
	exact := float64(u.PromptTokens-u.CachedTokens)*float64(rates.Input)/1e6 +
		float64(u.CachedTokens)*float64(rates.CacheRead)/1e6 +
		float64(u.CompletionTokens)*float64(rates.Output)/1e6
	got := rates.Cost(u)
	if float64(got) > exact {
		t.Fatalf("cost %d exceeds exact %.3f", got, exact)
	}
	if exact-float64(got) >= 3 {
		t.Fatalf("cost %d undercharges exact %.3f by 3 µUSD or more", got, exact)
	}
}

func TestCacheReadDiscount(t *testing.T) {
	rates := Rates{Input: 300_000, Output: 1_200_000, CacheRead: 30_000}
	// 8,000 cached tokens: 2,400 at the input rate vs 240 at the cache rate.
	if got := rates.CacheReadDiscount(Usage{PromptTokens: 10_000, CachedTokens: 8_000}); got != 2_160 {
		t.Fatalf("discount = %d, want 2160", got)
	}
	if got := rates.CacheReadDiscount(Usage{PromptTokens: 10_000}); got != 0 {
		t.Fatalf("no cache hit discount = %d, want 0", got)
	}
	// Clamped like Cost: cached beyond the prompt counts only up to the prompt.
	if got := rates.CacheReadDiscount(Usage{PromptTokens: 100, CachedTokens: 1_000}); got != 30-3 {
		t.Fatalf("over-reported discount = %d, want 27", got)
	}
	// Cost + discount == the cold cost of the same request.
	u := Usage{PromptTokens: 10_000, CachedTokens: 8_000, CompletionTokens: 500}
	cold := rates.Cost(Usage{PromptTokens: u.PromptTokens, CompletionTokens: u.CompletionTokens})
	if rates.Cost(u)+rates.CacheReadDiscount(u) != cold {
		t.Fatalf("cost %d + discount %d != cold %d", rates.Cost(u), rates.CacheReadDiscount(u), cold)
	}
}

func TestPlatformFee(t *testing.T) {
	tests := []struct {
		totalCost int64
		wantFee   int64
	}{
		// Default platform fee is 0% during the public alpha.
		{100_000, 0},
		{1_000_000, 0},
		{500_000, 0},
		{1_000, 0},
		{0, 0},
	}

	for _, tc := range tests {
		got := PlatformFee(tc.totalCost)
		if got != tc.wantFee {
			t.Errorf("PlatformFee(%d) = %d, want %d", tc.totalCost, got, tc.wantFee)
		}
	}
}

func TestProviderPayout(t *testing.T) {
	tests := []struct {
		totalCost  int64
		wantPayout int64
	}{
		// Providers keep 100% during the public alpha (0% default fee).
		{100_000, 100_000},
		{1_000_000, 1_000_000},
		{1_000, 1_000},
		{0, 0},
	}

	for _, tc := range tests {
		got := ProviderPayout(tc.totalCost)
		if got != tc.wantPayout {
			t.Errorf("ProviderPayout(%d) = %d, want %d", tc.totalCost, got, tc.wantPayout)
		}
	}
}

func TestPlatformFeeAndProviderPayoutSumToTotal(t *testing.T) {
	totals := []int64{1_000, 10_000, 100_000, 500_000, 1_000_000, 10_000_000}
	for _, total := range totals {
		fee := PlatformFee(total)
		payout := ProviderPayout(total)
		if fee+payout != total {
			t.Errorf("PlatformFee(%d) + ProviderPayout(%d) = %d + %d = %d, want %d",
				total, total, fee, payout, fee+payout, total)
		}
	}
}

func TestFormatPerMillionUSD(t *testing.T) {
	cases := map[int64]string{
		0:          "$0.0000",
		25_000:     "$0.0250",
		50_000:     "$0.0500",
		200_000:    "$0.2000",
		1_234_567:  "$1.2346",
		10_000_000: "$10.0000",
	}
	for in, want := range cases {
		if got := FormatPerMillionUSD(in); got != want {
			t.Errorf("FormatPerMillionUSD(%d) = %q, want %q", in, got, want)
		}
	}
}
