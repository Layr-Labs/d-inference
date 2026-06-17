package routingsim_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry/routingsim"
)

// TestRoutingSimCalibration is the regression anchor that proves the harness
// reproduces the observed prod behavior: on a warm, idle, capable fleet running
// at ~25 tok/s, the TTFT admission gate rejects requests above a prompt-size
// cliff of ~550-650 tokens even though every provider has free capacity.
//
// Root cause it pins: the preflight estimates prefill throughput as decode x 4
// (resolvedPrefillTPS in coordinator/registry/scheduler.go), i.e. ~100 tok/s
// for a 25 tok/s decoder, while the deadline (api.ttftDeadline, replicated as
// routingsim.TTFTDeadline) allows 5s + 1ms/token, implying ~1000 tok/s prefill.
// The 10x mismatch makes prefill dominate for prompts past ~550 tokens, so the
// estimated TTFT exceeds the deadline and the request is 429'd as
// "ttft_too_slow" on an otherwise-idle fleet.
//
// TODO: once registry.SetPrefillToDecodeRatio lands (currently on a separate
// branch, not on master), add a companion test asserting that raising the ratio
// to ~12 (a realistic prefill:decode ratio) moves the cliff well past 4000
// tokens — i.e. the same fleet + trace serves the large-prompt buckets that
// this test shows being rejected today.
func TestRoutingSimCalibration(t *testing.T) {
	const (
		model        = "mlx-community/Qwen3.5-9B-Instruct-4bit"
		providers    = 70
		medianDecode = 25.0 // tok/s, Apple Silicon median today
		decodeSpread = 2    // values cycle 23..27, median preserved at 25
		perBucket    = 250
		maxTokens    = 512
	)

	// Warm, idle, capable fleet: every provider has the model resident and no
	// active requests, so the only thing that can reject a request is the TTFT
	// estimate (never machine_busy / model_too_large).
	reg, err := routingsim.BuildFleet(nil, routingsim.FleetConfig{
		Model:        model,
		Providers:    providers,
		WarmFraction: 1.0,
		DecodeTPS:    routingsim.ClusteredDecodeTPS(medianDecode, decodeSpread),
	})
	if err != nil {
		t.Fatalf("BuildFleet: %v", err)
	}

	trace := routingsim.GenerateTrace(model, maxTokens, routingsim.CalibrationPromptMix(perBucket))
	results := routingsim.Run(reg, trace)
	report := routingsim.Summarize(results)
	cliff := routingsim.EstimatedCliff(results)

	t.Logf("estimated cliff: %d tokens (first prompt size rejected after a served one)", cliff)
	t.Logf("\n%s", report.String())

	// --- The bug only makes sense if capacity really is idle. ---
	if report.MachineBusy != 0 {
		t.Fatalf("expected 0 machine_busy on an idle fleet, got %d — capacity is not idle, "+
			"so a TTFT rejection would not prove the prefill-estimate bug", report.MachineBusy)
	}

	// --- Below the cliff: small prompts are essentially all served. ---
	small, ok := report.Bucket("0-500")
	if !ok || small.Total == 0 {
		t.Fatalf("bucket 0-500 missing or empty: %+v", small)
	}
	if rate := small.AcceptRate(); rate < 0.99 {
		t.Fatalf("bucket 0-500 accept rate = %.3f, want >= 0.99 (small prompts should be served)", rate)
	}

	// --- Above the cliff: prompts >= 750 are essentially all ttft-rejected. ---
	for _, label := range []string{"750-1000", "1000-2000", "2000-4000", "4000+"} {
		b, ok := report.Bucket(label)
		if !ok || b.Total == 0 {
			t.Fatalf("bucket %s missing or empty: %+v", label, b)
		}
		if rate := b.TTFTRejectRate(); rate < 0.99 {
			t.Fatalf("bucket %s ttft_too_slow rate = %.3f, want >= 0.99 (large prompts should be rejected on the cliff)", label, rate)
		}
		if b.Served != 0 {
			t.Fatalf("bucket %s served %d arrivals, want 0 above the cliff", label, b.Served)
		}
	}

	// --- The transition lands in the observed prod window of ~550-650 tokens. ---
	if cliff < 550 || cliff > 650 {
		t.Fatalf("estimated cliff = %d tokens, want within 550-650 (the observed prod cliff)", cliff)
	}
}
