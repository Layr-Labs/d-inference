package routingsim_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/routingsim"
)

const (
	simModel        = "mlx-community/Qwen3.5-9B-Instruct-4bit"
	simProviders    = 70
	simMedianDecode = 25.0 // tok/s, Apple Silicon median today
	simDecodeSpread = 2    // values cycle 23..27, median preserved at 25
	simPerBucket    = 250
	simMaxTokens    = 512
)

// buildSimFleet returns a warm, idle, capable fleet (every provider has the
// model resident with no active requests, so the only thing that can reject is
// the TTFT estimate — never machine_busy / model_too_large) plus the standard
// calibration trace.
func buildSimFleet(t *testing.T) (*registry.Registry, []routingsim.Arrival) {
	t.Helper()
	reg, err := routingsim.BuildFleet(nil, routingsim.FleetConfig{
		Model:        simModel,
		Providers:    simProviders,
		WarmFraction: 1.0,
		DecodeTPS:    routingsim.ClusteredDecodeTPS(simMedianDecode, simDecodeSpread),
	})
	if err != nil {
		t.Fatalf("BuildFleet: %v", err)
	}
	return reg, routingsim.GenerateTrace(simModel, simMaxTokens, routingsim.CalibrationPromptMix(simPerBucket))
}

// TestRoutingSimCalibration is the regression anchor that proves the harness
// reproduces the observed prod behavior under the LEGACY prefill estimate
// (decode×4 ≈ 100 tok/s vs a deadline implying ~1000 tok/s): on a warm, idle,
// capable fleet the hard TTFT gate rejects requests above a ~550–650 token
// cliff even though every provider has free capacity (machine_busy == 0).
func TestRoutingSimCalibration(t *testing.T) {
	defer routingsim_setRatio(t, 4.0)() // legacy ×4 estimate

	reg, trace := buildSimFleet(t)
	results := routingsim.Run(reg, trace) // hard gate
	report := routingsim.Summarize(results)
	cliff := routingsim.EstimatedCliff(results)
	t.Logf("legacy ×4 cliff: %d tokens\n%s", cliff, report.String())

	if report.MachineBusy != 0 {
		t.Fatalf("expected 0 machine_busy on an idle fleet, got %d", report.MachineBusy)
	}
	if small, ok := report.Bucket("0-500"); !ok || small.AcceptRate() < 0.99 {
		t.Fatalf("bucket 0-500 accept rate = %.3f, want >= 0.99", small.AcceptRate())
	}
	for _, label := range []string{"750-1000", "1000-2000", "2000-4000", "4000+"} {
		b, ok := report.Bucket(label)
		if !ok || b.TTFTRejectRate() < 0.99 || b.Served != 0 {
			t.Fatalf("bucket %s: want ~all ttft-rejected, got served=%d ttftRate=%.3f", label, b.Served, b.TTFTRejectRate())
		}
	}
	if cliff < 550 || cliff > 650 {
		t.Fatalf("legacy cliff = %d tokens, want within the observed 550-650 window", cliff)
	}
}

// TestRoutingSimPrefillRatio12MovesCliff proves the W0/#381 prefill fix: raising
// the decode→prefill fallback to ×12 (the routing-v2 default) moves the cliff
// from ~600 to ~2100 tokens on the SAME fleet+trace — the 750–2000 token buckets
// that the legacy estimate rejected are now served, even under the hard gate.
func TestRoutingSimPrefillRatio12MovesCliff(t *testing.T) {
	defer routingsim_setRatio(t, 12.0)()

	reg, trace := buildSimFleet(t)
	results := routingsim.Run(reg, trace) // still the hard gate — only the estimate changed
	report := routingsim.Summarize(results)
	cliff := routingsim.EstimatedCliff(results)
	t.Logf("×12 cliff: %d tokens\n%s", cliff, report.String())

	if report.MachineBusy != 0 {
		t.Fatalf("expected 0 machine_busy, got %d", report.MachineBusy)
	}
	// Buckets that were ~100% rejected under ×4 are now served under ×12.
	for _, label := range []string{"0-500", "500-750", "750-1000", "1000-2000"} {
		if b, ok := report.Bucket(label); !ok || b.AcceptRate() < 0.99 {
			t.Fatalf("bucket %s accept rate = %.3f, want >= 0.99 with ×12 prefill", label, b.AcceptRate())
		}
	}
	if cliff < 2000 {
		t.Fatalf("×12 cliff = %d tokens, want > 2000 (moved out from ~600)", cliff)
	}
}

// TestRoutingSimSoftGateServesEverything proves the soft TTFT gate (PR #381):
// with TTFT a routing preference rather than a hard reject, every arrival that
// has a candidate provider is served regardless of prompt size — no
// ttft_too_slow rejections on an idle fleet, across all buckets.
func TestRoutingSimSoftGateServesEverything(t *testing.T) {
	defer routingsim_setRatio(t, 12.0)()

	reg, trace := buildSimFleet(t)
	results := routingsim.RunWithGate(reg, trace, true) // soft gate
	report := routingsim.Summarize(results)
	t.Logf("soft gate:\n%s", report.String())

	if report.MachineBusy != 0 {
		t.Fatalf("expected 0 machine_busy, got %d", report.MachineBusy)
	}
	for _, label := range []string{"0-500", "500-750", "750-1000", "1000-2000", "2000-4000", "4000+"} {
		b, ok := report.Bucket(label)
		if !ok || b.AcceptRate() < 0.999 {
			t.Fatalf("bucket %s accept rate = %.3f, want 1.0 under the soft gate", label, b.AcceptRate())
		}
	}
}

// routingsim_setRatio sets the decode→prefill fallback ratio and returns a
// restore func (call via defer) so each test is isolated from the package-global.
func routingsim_setRatio(t *testing.T, ratio float64) func() {
	t.Helper()
	prev := registry.PrefillToDecodeRatio()
	registry.SetPrefillToDecodeRatio(ratio)
	return func() { registry.SetPrefillToDecodeRatio(prev) }
}
