package registry

import (
	"math"
	"testing"
)

func approxEqual(a, b, tol float64) bool {
	return math.Abs(a-b) <= tol
}

func TestExpectedDecodeTPS(t *testing.T) {
	tests := []struct {
		name          string
		activeParams  float64
		bytesPerParam float64
		bandwidthGBps float64
		efficiency    float64
		want          float64
		tol           float64
	}{
		{
			// gemma-4-26b-qat-4bit: ~4B active, 4-bit, M-Max ~400 GB/s.
			name: "gemma 4B-active 4bit on M-Max", activeParams: 4.0e9,
			bytesPerParam: BytesPerParam4Bit, bandwidthGBps: 400, efficiency: 0.80,
			want: 142.2, tol: 1.0,
		},
		{
			// gpt-oss-20b: ~3.6B active, 4-bit, M-Max ~400 GB/s.
			name: "gpt-oss 3.6B-active 4bit on M-Max", activeParams: 3.6e9,
			bytesPerParam: BytesPerParam4Bit, bandwidthGBps: 400, efficiency: 0.80,
			want: 158.0, tol: 1.0,
		},
		{
			// If gemma is read as a DENSE 26B model, the expectation collapses to
			// ~22 tok/s — which is exactly the production observation.
			name: "dense 26B 4bit on M-Max", activeParams: 26.0e9,
			bytesPerParam: BytesPerParam4Bit, bandwidthGBps: 400, efficiency: 0.80,
			want: 21.9, tol: 1.0,
		},
		{
			name: "zero active params", activeParams: 0,
			bytesPerParam: BytesPerParam4Bit, bandwidthGBps: 400, efficiency: 0.80,
			want: 0, tol: 0,
		},
		{
			name: "zero bandwidth", activeParams: 4.0e9,
			bytesPerParam: BytesPerParam4Bit, bandwidthGBps: 0, efficiency: 0.80,
			want: 0, tol: 0,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ExpectedDecodeTPS(tc.activeParams, tc.bytesPerParam, tc.bandwidthGBps, tc.efficiency)
			if !approxEqual(got, tc.want, tc.tol) {
				t.Fatalf("ExpectedDecodeTPS = %.3f, want %.3f ± %.3f", got, tc.want, tc.tol)
			}
		})
	}
}

// TestThroughputAnomaly_GemmaFlaggedGptossNot is the core acceptance test: with
// the production decode numbers on an M-Max (gemma ~21 tok/s, gpt-oss ~69 tok/s),
// gemma must be flagged as a throughput anomaly and gpt-oss must not.
func TestThroughputAnomaly_GemmaFlaggedGptossNot(t *testing.T) {
	cfg := DefaultThroughputAnomalyConfig()

	gemma := EvaluateThroughputAnomaly(ThroughputAnomalyInput{
		Model:       "gemma-4-26b-qat-4bit",
		ChipClass:   "M3 Max", // 400 GB/s via the table
		ObservedTPS: 21,
		Samples:     10,
	}, cfg)
	if !gemma.Evaluated {
		t.Fatalf("gemma should be evaluated, got skip=%q", gemma.SkipReason)
	}
	if !gemma.Anomalous {
		t.Fatalf("gemma should be flagged: observed=%.1f expected=%.1f ratio=%.3f (threshold %.2f)",
			gemma.ObservedTPS, gemma.ExpectedTPS, gemma.Ratio, cfg.RatioThreshold)
	}
	if gemma.Ratio >= cfg.RatioThreshold {
		t.Fatalf("gemma ratio %.3f should be < %.2f", gemma.Ratio, cfg.RatioThreshold)
	}

	gptoss := EvaluateThroughputAnomaly(ThroughputAnomalyInput{
		Model:       "gpt-oss-20b",
		ChipClass:   "M3 Max",
		ObservedTPS: 69,
		Samples:     10,
	}, cfg)
	if !gptoss.Evaluated {
		t.Fatalf("gpt-oss should be evaluated, got skip=%q", gptoss.SkipReason)
	}
	if gptoss.Anomalous {
		t.Fatalf("gpt-oss should NOT be flagged: observed=%.1f expected=%.1f ratio=%.3f (threshold %.2f)",
			gptoss.ObservedTPS, gptoss.ExpectedTPS, gptoss.Ratio, cfg.RatioThreshold)
	}
	if gptoss.Ratio < cfg.RatioThreshold {
		t.Fatalf("gpt-oss ratio %.3f should be >= %.2f", gptoss.Ratio, cfg.RatioThreshold)
	}

	t.Logf("gemma  ratio=%.3f (observed=%.0f expected=%.1f) -> flagged",
		gemma.Ratio, gemma.ObservedTPS, gemma.ExpectedTPS)
	t.Logf("gptoss ratio=%.3f (observed=%.0f expected=%.1f) -> ok",
		gptoss.Ratio, gptoss.ObservedTPS, gptoss.ExpectedTPS)
}

// TestThroughputAnomaly_GemmaFlaggedAcrossMaxTier checks the verdict holds for
// the whole Max tier (the class to which gemma's ~21 tok/s dense read maps).
func TestThroughputAnomaly_GemmaFlaggedAcrossMaxTier(t *testing.T) {
	cfg := DefaultThroughputAnomalyConfig()
	for _, chip := range []string{"M1 Max", "M2 Max", "M3 Max"} {
		res := EvaluateThroughputAnomaly(ThroughputAnomalyInput{
			Model: "gemma-4-26b-qat-4bit", ChipClass: chip, ObservedTPS: 21, Samples: 5,
		}, cfg)
		if !res.Anomalous {
			t.Errorf("%s: gemma@21 should be flagged (ratio=%.3f expected=%.1f)", chip, res.Ratio, res.ExpectedTPS)
		}
	}
}

func TestThroughputAnomaly_BandwidthOverride(t *testing.T) {
	cfg := DefaultThroughputAnomalyConfig()
	// Provider-reported bandwidth wins over the chip table even for an unknown
	// class string.
	res := EvaluateThroughputAnomaly(ThroughputAnomalyInput{
		Model: "gemma-4-26b-qat-4bit", ChipClass: "Unknownchip",
		BandwidthGBps: 400, ObservedTPS: 21, Samples: 5,
	}, cfg)
	if !res.Evaluated {
		t.Fatalf("expected evaluated with bandwidth override, skip=%q", res.SkipReason)
	}
	if res.BandwidthGBps != 400 {
		t.Fatalf("bandwidth override not used: got %.0f", res.BandwidthGBps)
	}
	if !res.Anomalous {
		t.Fatalf("gemma@21 with 400 GB/s override should be flagged, ratio=%.3f", res.Ratio)
	}
}

func TestThroughputAnomaly_InsufficientSamples(t *testing.T) {
	cfg := DefaultThroughputAnomalyConfig() // MinSamples = 3
	res := EvaluateThroughputAnomaly(ThroughputAnomalyInput{
		Model: "gemma-4-26b-qat-4bit", ChipClass: "M3 Max", ObservedTPS: 21, Samples: 1,
	}, cfg)
	if res.Evaluated {
		t.Fatalf("should not evaluate with 1 sample (min %d)", cfg.MinSamples)
	}
	if res.Anomalous {
		t.Fatalf("should not flag with insufficient samples")
	}
	if res.SkipReason != "insufficient_samples" {
		t.Fatalf("skip reason = %q, want insufficient_samples", res.SkipReason)
	}
}

func TestThroughputAnomaly_UnknownModelAndChipSkipped(t *testing.T) {
	cfg := DefaultThroughputAnomalyConfig()

	unknownModel := EvaluateThroughputAnomaly(ThroughputAnomalyInput{
		Model: "totally-unknown-model", ChipClass: "M3 Max", ObservedTPS: 5, Samples: 99,
	}, cfg)
	if unknownModel.Evaluated || unknownModel.Anomalous {
		t.Fatalf("unknown model must be skipped, got %+v", unknownModel)
	}
	if unknownModel.SkipReason != "unknown_model" {
		t.Fatalf("skip reason = %q, want unknown_model", unknownModel.SkipReason)
	}

	unknownChip := EvaluateThroughputAnomaly(ThroughputAnomalyInput{
		Model: "gemma-4-26b-qat-4bit", ChipClass: "Z9 Hyper", ObservedTPS: 5, Samples: 99,
	}, cfg)
	if unknownChip.Evaluated || unknownChip.Anomalous {
		t.Fatalf("unknown chip must be skipped, got %+v", unknownChip)
	}
	if unknownChip.SkipReason != "unknown_chip" {
		t.Fatalf("skip reason = %q, want unknown_chip", unknownChip.SkipReason)
	}
}

// TestThroughputAnomaly_HealthyGemmaNotFlagged confirms that once gemma's MoE
// decode is fixed (~140 tok/s on an M-Max), it is no longer flagged.
func TestThroughputAnomaly_HealthyGemmaNotFlagged(t *testing.T) {
	cfg := DefaultThroughputAnomalyConfig()
	res := EvaluateThroughputAnomaly(ThroughputAnomalyInput{
		Model: "gemma-4-26b-qat-4bit", ChipClass: "M3 Max", ObservedTPS: 140, Samples: 10,
	}, cfg)
	if res.Anomalous {
		t.Fatalf("healthy gemma (140 tok/s) should not be flagged, ratio=%.3f", res.Ratio)
	}
}

func TestLookupModelDecodeClass(t *testing.T) {
	c, ok := LookupModelDecodeClass("gpt-oss-20b")
	if !ok {
		t.Fatal("gpt-oss-20b should be known")
	}
	if c.ActiveParams != 3.6e9 {
		t.Errorf("gpt-oss active params = %g, want 3.6e9", c.ActiveParams)
	}
	if c.BytesPerParam != BytesPerParam4Bit {
		t.Errorf("gpt-oss bytes/param = %g, want %g", c.BytesPerParam, BytesPerParam4Bit)
	}
	// Case-insensitive match.
	if _, ok := LookupModelDecodeClass("GEMMA-4-26B-QAT-4BIT"); !ok {
		t.Error("case-insensitive lookup should match gemma")
	}
	if _, ok := LookupModelDecodeClass("nope"); ok {
		t.Error("unknown model should not match")
	}
}

func TestBytesPerParamForModelID(t *testing.T) {
	tests := map[string]float64{
		"gemma-4-26b-qat-4bit": BytesPerParam4Bit,
		"some-model-4bit":      BytesPerParam4Bit,
		"some-model-q4":        BytesPerParam4Bit,
		"some-model-8bit":      BytesPerParam8Bit,
		"some-model-q8":        BytesPerParam8Bit,
		"some-model-bf16":      BytesPerParamBF16,
		"plain-model":          BytesPerParamBF16,
	}
	for id, want := range tests {
		if got := BytesPerParamForModelID(id); got != want {
			t.Errorf("BytesPerParamForModelID(%q) = %g, want %g", id, got, want)
		}
	}
}

func TestResolveChipClass(t *testing.T) {
	tests := []struct {
		family, tier, chipName, want string
	}{
		{"M3", "Max", "", "M3 Max"},
		{"M3", "max", "", "M3 Max"},
		{"M4", "Pro", "", "M4 Pro"},
		{"M2", "", "", "M2"},
		{"M3 Max", "", "", "M3 Max"},       // family already includes tier
		{"", "", "Apple M3 Max", "M3 Max"}, // fall back to marketing name
		{"", "", "Apple M1", "M1"},
		{"", "", "Intel Core i9", ""}, // no Apple generation token
		{"", "", "", ""},
	}
	for _, tc := range tests {
		if got := ResolveChipClass(tc.family, tc.tier, tc.chipName); got != tc.want {
			t.Errorf("ResolveChipClass(%q,%q,%q) = %q, want %q", tc.family, tc.tier, tc.chipName, got, tc.want)
		}
	}
}

func TestChipBandwidthForClass(t *testing.T) {
	if bw := ChipBandwidthForClass("M3 Max"); bw != 400 {
		t.Errorf("M3 Max bandwidth = %g, want 400", bw)
	}
	if bw := ChipBandwidthForClass("M4 Pro"); bw != 273 {
		t.Errorf("M4 Pro bandwidth = %g, want 273", bw)
	}
	// Unknown tier falls back to the bare generation.
	if bw := ChipBandwidthForClass("M3 Quantum"); bw != 100 {
		t.Errorf("M3 Quantum bandwidth = %g, want 100 (M3 base fallback)", bw)
	}
	if bw := ChipBandwidthForClass("Z9"); bw != 0 {
		t.Errorf("unknown generation bandwidth = %g, want 0", bw)
	}
	if bw := ChipBandwidthForClass(""); bw != 0 {
		t.Errorf("empty class bandwidth = %g, want 0", bw)
	}
}
