package routingcost

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry/throughput"
)

func TestResolvePrefillTPSPrefersObserved(t *testing.T) {
	// No measured rate: the resolver returns the existing prefillTPS chain
	// (resolvedPrefillTPS: benchmark → decode×12) unchanged. This is the
	// today-fleet path and MUST be a no-op.
	if got := ResolvePrefillTPS(snapPtr(routingSnapshot{PrefillTPS: 600})); got != 600 {
		t.Fatalf("fallback prefill = %v, want 600 (×12 chain preserved)", got)
	}
	// A non-positive observed value is treated as unmeasured → fallback.
	if got := ResolvePrefillTPS(snapPtr(routingSnapshot{PrefillTPS: 600, ObservedPrefillTPS: 0})); got != 600 {
		t.Fatalf("zero observed prefill = %v, want 600 (fallback)", got)
	}
	// A measured per-slot prefill EWMA wins over the static chain.
	if got := ResolvePrefillTPS(snapPtr(routingSnapshot{PrefillTPS: 600, ObservedPrefillTPS: 1800})); got != 1800 {
		t.Fatalf("observed prefill = %v, want 1800 (measured preferred)", got)
	}
	// The result is clamped to MaxPrefillTPS so one outlier heartbeat cannot
	// collapse the TTFT estimate.
	if got := ResolvePrefillTPS(snapPtr(routingSnapshot{ObservedPrefillTPS: MaxPrefillTPS * 2})); got != MaxPrefillTPS {
		t.Fatalf("clamped observed prefill = %v, want %v", got, MaxPrefillTPS)
	}
}

func TestTTFTMsFromSnapshotUsesObservedPrefillTPS(t *testing.T) {
	const prompt = 1000
	// Fallback path: no measured prefill → ttft uses snap.prefillTPS (the ×12
	// chain), identical to the pre-wiring behavior. statePenalty(running)=0,
	// queuedPrefill=0, firstDecode=1000/decode.
	fallback := routingSnapshot{
		HasBackendCapacity: true,
		SlotState:          "running",
		PrefillTPS:         600, // e.g. decode 50 × 12
		DecodeTPS:          50,
	}
	fallbackTTFT := RawTTFTMs(snapPtr(fallback), prompt)
	wantFallback := float64(prompt)/600*1000 + 1000.0/50.0
	if d := fallbackTTFT - wantFallback; d > 0.01 || d < -0.01 {
		t.Fatalf("fallback TTFT = %.4f, want %.4f (×12 chain preserved)", fallbackTTFT, wantFallback)
	}

	// Measured path: a 3× faster observed prefill lowers only the prefill term.
	observed := fallback
	observed.ObservedPrefillTPS = 1800
	observedTTFT := RawTTFTMs(snapPtr(observed), prompt)
	wantObserved := float64(prompt)/1800*1000 + 1000.0/50.0
	if d := observedTTFT - wantObserved; d > 0.01 || d < -0.01 {
		t.Fatalf("observed TTFT = %.4f, want %.4f (measured prefill used)", observedTTFT, wantObserved)
	}
	if observedTTFT >= fallbackTTFT {
		t.Fatalf("observed TTFT %.2f should be below fallback TTFT %.2f", observedTTFT, fallbackTTFT)
	}
}

func TestProjectedPerRequestDecodeTPS(t *testing.T) {
	k := throughput.LoadFactor
	abs := func(x float64) float64 {
		if x < 0 {
			return -x
		}
		return x
	}
	approx := func(a, b float64) bool { return abs(a-b) < 0.01 }

	// Static fallback (no observed rate), idle provider: rate at batch 1 = static/(1+k).
	if got, want := ProjectedPerRequestDecodeTPS(snapPtr(routingSnapshot{DecodeTPS: 25})), 25.0/(1+k); !approx(got, want) {
		t.Fatalf("static idle projected = %.2f, want %.2f", got, want)
	}
	// Observed rate measured at batch 2 is unwound to a solo rate, then reapplied
	// at batch 3 (the new request joins): solo = obs*(1+2k); proj = solo/(1+3k).
	snap := routingSnapshot{DecodeTPS: 25, ObservedDecodeTPS: 20, BackendRunning: 2}
	if got, want := ProjectedPerRequestDecodeTPS(snapPtr(snap)), 20.0*(1+2*k)/(1+3*k); !approx(got, want) {
		t.Fatalf("observed projected = %.2f, want %.2f", got, want)
	}
	// No decode info -> 0 (treated as below any positive floor).
	if got := ProjectedPerRequestDecodeTPS(snapPtr(routingSnapshot{})); got != 0 {
		t.Fatalf("empty snapshot projected = %.2f, want 0", got)
	}
}
