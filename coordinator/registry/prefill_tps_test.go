package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// --- Prefill sample ring ---

func TestPrefillMedianReturnsMedianAndCount(t *testing.T) {
	r := NewTPSRegistry()
	for _, v := range []float64{9000, 5000, 6500, 6000, 7000} {
		r.RecordPrefill("model-a", "m4", v)
	}
	tps, n := r.PrefillMedian("model-a", "m4")
	if tps != 6500 || n != 5 {
		t.Fatalf("PrefillMedian = (%v, %d), want (6500, 5)", tps, n)
	}
	// The decode stores must be untouched by prefill recording.
	if got := r.Median("model-a", "m4"); got != 0 {
		t.Fatalf("Median = %v, want 0 (RecordPrefill must not feed the decode store)", got)
	}
	if _, n := r.SoloMedian("model-a", "m4"); n != 0 {
		t.Fatalf("SoloMedian count = %d, want 0", n)
	}
}

func TestPrefillMedianEmptyInvalidAndFIFO(t *testing.T) {
	r := NewTPSRegistry()
	if tps, n := r.PrefillMedian("missing", "m4"); tps != 0 || n != 0 {
		t.Fatalf("PrefillMedian(empty) = (%v, %d), want (0, 0)", tps, n)
	}
	r.RecordPrefill("model", "m4", 0)
	r.RecordPrefill("model", "m4", -3)
	r.RecordPrefill("", "m4", 5000)
	if tps, n := r.PrefillMedian("model", "m4"); tps != 0 || n != 0 {
		t.Fatalf("PrefillMedian(after invalid samples) = (%v, %d), want (0, 0)", tps, n)
	}
	for i := 0; i < 50; i++ {
		r.RecordPrefill("model", "m4", 1000)
	}
	for i := 0; i < 10; i++ {
		r.RecordPrefill("model", "m4", 2000)
	}
	// 40 × 1000 + 10 × 2000 after FIFO eviction → median 1000, count capped at 50.
	if tps, n := r.PrefillMedian("model", "m4"); tps != 1000 || n != 50 {
		t.Fatalf("PrefillMedian = (%v, %d), want (1000, 50) after FIFO eviction", tps, n)
	}
}

// --- Heartbeat ingest ---

// TestPrefillRecordingThroughHeartbeat drives the REAL heartbeat ingest path:
// observed_prefill_tps > 0 feeds the prefill ring UNCONDITIONALLY (no solo
// gating — prefill is per-request compute-bound; the ingest-gating rationale is
// in prefill_tps.go), while out-of-range values are zeroed by
// clampBackendCapacity and never reach the ring.
func TestPrefillRecordingThroughHeartbeat(t *testing.T) {
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "box", gptossBuild, 30)

	hb := func(slots []protocol.BackendSlotCapacity) {
		reg.Heartbeat("box", &protocol.HeartbeatMessage{
			Type:   protocol.TypeHeartbeat,
			Status: "serving",
			BackendCapacity: &protocol.BackendCapacity{
				TotalMemoryGB: 64,
				Slots:         slots,
			},
		})
	}

	// A real measurement above the OLD 5000 ceiling (the fleet p50 is 6,523)
	// must survive ingest and land in the ring — this is exactly why the #453
	// ceiling raise (maxPrefillTPS 5000 → 20000) is a prerequisite for the
	// medians: under the old ceiling this sample would have been zeroed.
	hb([]protocol.BackendSlotCapacity{
		{Model: gptossBuild, State: "running", NumRunning: 1, ObservedPrefillTPS: 6500},
	})
	if tps, n := reg.tpsRegistry.PrefillMedian(gptossBuild, "M3"); tps != 6500 || n != 1 {
		t.Fatalf("PrefillMedian after heartbeat = (%v, %d), want (6500, 1)", tps, n)
	}

	// A CONTENDED box still records (deliberately un-gated, unlike RecordSolo):
	// co-resident decode does not invalidate a compute-bound prefill EWMA.
	hb([]protocol.BackendSlotCapacity{
		{Model: gptossBuild, State: "running", NumRunning: 2, NumWaiting: 1, ObservedPrefillTPS: 7000},
		{Model: gemmaBuild, State: "running", NumRunning: 3, ObservedDecodeTPS: 4},
	})
	if _, n := reg.tpsRegistry.PrefillMedian(gptossBuild, "M3"); n != 2 {
		t.Fatalf("prefill samples after contended heartbeat = %d, want 2 (no solo gating)", n)
	}

	// Out-of-range garbage (the prefix-cache-hit EWMA overflow) is zeroed at
	// the clamp and must NOT be recorded; an unreported slot (0) records nothing.
	hb([]protocol.BackendSlotCapacity{
		{Model: gptossBuild, State: "running", ObservedPrefillTPS: 25_000},
	})
	hb([]protocol.BackendSlotCapacity{
		{Model: gptossBuild, State: "running", ObservedPrefillTPS: 0},
	})
	if _, n := reg.tpsRegistry.PrefillMedian(gptossBuild, "M3"); n != 2 {
		t.Fatalf("prefill samples after garbage/zero heartbeats = %d, want 2", n)
	}
}

// TestPrefillHeartbeatDedupsResentEWMA (review fix): the per-slot prefill EWMA
// is PERSISTENT provider state resent on every 30s heartbeat, so an idle box
// re-reporting one cold-prefill measurement must count as ONE sample — not one
// per tick, which would satisfy EIGENINFERENCE_TTFT_PREFILL_MIN_SAMPLES=5 with
// a single real observation after five idle ticks. Only a CHANGED value (a new
// measurement folded into the EWMA) records; per-model tracking keeps
// co-resident slots independent. Fails without the lastRecordedPrefillTPS gate
// in Heartbeat (the resent value records 5 samples).
func TestPrefillHeartbeatDedupsResentEWMA(t *testing.T) {
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "box", gptossBuild, 30)

	hb := func(slots []protocol.BackendSlotCapacity) {
		reg.Heartbeat("box", &protocol.HeartbeatMessage{
			Type:   protocol.TypeHeartbeat,
			Status: "serving",
			BackendCapacity: &protocol.BackendCapacity{
				TotalMemoryGB: 64,
				Slots:         slots,
			},
		})
	}

	// Five idle ticks resending the SAME EWMA = one measurement, one sample.
	for i := 0; i < 5; i++ {
		hb([]protocol.BackendSlotCapacity{
			{Model: gptossBuild, State: "idle", ObservedPrefillTPS: 6500},
		})
	}
	if _, n := reg.tpsRegistry.PrefillMedian(gptossBuild, "M3"); n != 1 {
		t.Fatalf("prefill samples after 5 identical heartbeats = %d, want 1 (a resent EWMA is not a new observation)", n)
	}

	// A changed value IS a new observation — recorded. And a change BACK to a
	// previously seen value is also new (the gate compares against the last
	// recorded value, not a history).
	hb([]protocol.BackendSlotCapacity{
		{Model: gptossBuild, State: "running", ObservedPrefillTPS: 7000},
	})
	hb([]protocol.BackendSlotCapacity{
		{Model: gptossBuild, State: "running", ObservedPrefillTPS: 6500},
	})
	if _, n := reg.tpsRegistry.PrefillMedian(gptossBuild, "M3"); n != 3 {
		t.Fatalf("prefill samples after two genuine changes = %d, want 3", n)
	}

	// Per-model independence: a co-resident slot reporting the same NUMBER for a
	// different model is that model's first observation.
	hb([]protocol.BackendSlotCapacity{
		{Model: gptossBuild, State: "running", ObservedPrefillTPS: 6500},
		{Model: gemmaBuild, State: "running", ObservedPrefillTPS: 6500},
	})
	if _, n := reg.tpsRegistry.PrefillMedian(gptossBuild, "M3"); n != 3 {
		t.Fatalf("gpt-oss samples after unchanged resend = %d, want 3", n)
	}
	if _, n := reg.tpsRegistry.PrefillMedian(gemmaBuild, "M3"); n != 1 {
		t.Fatalf("gemma samples = %d, want 1 (per-model tracking)", n)
	}
}

// TestPrefillIngestZeroedUnderOldCeiling documents the ceiling interaction the
// absorbed #453 change fixes: with the ceiling back at the legacy 5000, a REAL
// p50-scale measurement (6500) is zeroed at ingest and the median ring starves.
func TestPrefillIngestZeroedUnderOldCeiling(t *testing.T) {
	t.Cleanup(func() { SetMaxPrefillTPS(defaultMaxPrefillTPS) })
	SetMaxPrefillTPS(5000)
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "box", gptossBuild, 30)
	reg.Heartbeat("box", &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: gptossBuild, State: "running", ObservedPrefillTPS: 6500},
			},
		},
	})
	if _, n := reg.tpsRegistry.PrefillMedian(gptossBuild, "M3"); n != 0 {
		t.Fatalf("prefill samples under the old 5000 ceiling = %d, want 0 (zeroed at ingest)", n)
	}
}

// --- TTFT estimation ---

// longPromptRequest is the production overshoot shape: gpt-oss's p90 prompt of
// 13,711 tokens against the 5s hard TTFT deadline.
func longPromptRequest(id string) *PendingRequest {
	return &PendingRequest{
		RequestID:             id,
		Model:                 gptossBuild,
		EstimatedPromptTokens: 13_711,
		RequestedMaxTokens:    256,
		MaxTTFTMs:             5_000,
	}
}

// seedPrefillMedian records n gated samples for (model, chip M3).
func seedPrefillMedian(reg *Registry, model string, n int, tps float64) {
	for i := 0; i < n; i++ {
		reg.tpsRegistry.RecordPrefill(model, "M3", tps)
	}
}

// TestPrefillMedianLongPromptRegression replicates the production overshoot:
// a 13.7k-token prompt on a warm box whose real (fleet-measured) prefill is
// 6,500 tok/s. The ratio-derived estimate (decode 30 × 12 = 360 tok/s → ~38s
// "TTFT") rejects it at the 5s deadline — the ttft_too_slow misprediction class
// killing 18.2k requests/day — while the trusted per-(model, chip) median
// admits it (13,711 / 6,500 ≈ 2.1s). Fails without the median layer in
// prefillTPSForSnapshot.
func TestPrefillMedianLongPromptRegression(t *testing.T) {
	t.Setenv(ttftPrefillMediansEnv, "true") // pin the default against ambient operator env
	t.Setenv(ttftPrefillMinSamplesEnv, "5")
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "warm-box", gptossBuild, 30)
	seedPrefillMedian(reg, gptossBuild, 5, 6500)

	p, decision := reg.ReserveProviderEx(gptossBuild, longPromptRequest("long-prompt-1"))
	if p == nil {
		t.Fatalf("long prompt rejected (TTFTRejections=%d, bestTTFT=%.0fms) — the trusted prefill median must admit it", decision.TTFTRejections, decision.BestTTFTMs)
	}
	if decision.TTFTMs <= 0 || decision.TTFTMs >= 5_000 {
		t.Fatalf("median-based TTFT estimate = %.0fms, want ~2100ms (well under the 5s deadline)", decision.TTFTMs)
	}
	p.RemovePending("long-prompt-1")
	reg.SetProviderIdle(p.ID)

	// Kill switch: EIGENINFERENCE_TTFT_PREFILL_MEDIANS=false restores the pure
	// ratio path — the same request is rejected on the ~38s misprediction.
	t.Setenv(ttftPrefillMediansEnv, "false")
	if p, decision := reg.ReserveProviderEx(gptossBuild, longPromptRequest("long-prompt-2")); p != nil {
		t.Fatalf("kill switch off: long prompt admitted with TTFT %.0fms — must reject on the ratio-derived estimate", decision.TTFTMs)
	} else if decision.TTFTRejections != 1 {
		t.Fatalf("kill switch off: TTFTRejections = %d, want 1", decision.TTFTRejections)
	}
}

// TestPrefillMedianMinSampleFloor: below EIGENINFERENCE_TTFT_PREFILL_MIN_SAMPLES
// the median is not trusted (ratio path → reject); at the floor it is.
func TestPrefillMedianMinSampleFloor(t *testing.T) {
	t.Setenv(ttftPrefillMediansEnv, "true")
	t.Setenv(ttftPrefillMinSamplesEnv, "5")
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "warm-box", gptossBuild, 30)

	seedPrefillMedian(reg, gptossBuild, 4, 6500)
	if p, _ := reg.ReserveProviderEx(gptossBuild, longPromptRequest("below-floor")); p != nil {
		t.Fatalf("4 samples (< default floor 5): median must not be trusted yet")
	}
	seedPrefillMedian(reg, gptossBuild, 1, 6500)
	p, _ := reg.ReserveProviderEx(gptossBuild, longPromptRequest("at-floor"))
	if p == nil {
		t.Fatalf("5 samples (= default floor): median must be trusted")
	}
	p.RemovePending("at-floor")
	reg.SetProviderIdle(p.ID)

	// A raised floor un-trusts the same median again (live-read env).
	t.Setenv(ttftPrefillMinSamplesEnv, "6")
	if p, _ := reg.ReserveProviderEx(gptossBuild, longPromptRequest("raised-floor")); p != nil {
		t.Fatalf("floor raised to 6: 5 samples must no longer be trusted")
	}
}

// TestPrefillMedianPreflightConsistency: the capacity preflight's bestTTFT uses
// the same estimate, so the shed decision and Retry-After agree with dispatch.
func TestPrefillMedianPreflightConsistency(t *testing.T) {
	t.Setenv(ttftPrefillMediansEnv, "true")
	t.Setenv(ttftPrefillMinSamplesEnv, "5")
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "warm-box", gptossBuild, 30)

	_, _, _, bestTTFT, hasTTFT := reg.QuickCapacityCheckWithTTFTForRequest(gptossBuild, 13_711, 256, RequestTraits{}, false)
	if !hasTTFT || bestTTFT < 30*time.Second {
		t.Fatalf("ratio-path preflight bestTTFT = (%v, %v), want ~38s (the overshoot)", bestTTFT, hasTTFT)
	}
	seedPrefillMedian(reg, gptossBuild, 5, 6500)
	_, _, _, bestTTFT, hasTTFT = reg.QuickCapacityCheckWithTTFTForRequest(gptossBuild, 13_711, 256, RequestTraits{}, false)
	if !hasTTFT || bestTTFT > 4*time.Second {
		t.Fatalf("median preflight bestTTFT = (%v, %v), want ~2.1s", bestTTFT, hasTTFT)
	}
}

// TestPrefillTPSForSnapshotResolutionOrder pins the full resolution chain of
// prefillTPSForSnapshot: own observed EWMA → trusted median → (enforce-only)
// fallback anchor → static ratio chain, with the maxPrefillTPS cap on top.
func TestPrefillTPSForSnapshotResolutionOrder(t *testing.T) {
	base := routingSnapshot{prefillTPS: 360, hasBackendCapacity: true}
	median := func(tps float64, n int) routingSnapshot {
		s := base
		s.prefillMedianTPS = tps
		s.prefillMedianSamples = n
		return s
	}
	cases := []struct {
		name        string
		snap        routingSnapshot
		recalibrate bool
		want        float64
	}{
		{"static_ratio_chain", base, false, 360},
		{"own_observation_wins", func() routingSnapshot {
			s := median(6500, 50)
			s.observedPrefillTPS = 9000
			return s
		}(), true, 9000},
		{"trusted_median_replaces_static", median(6500, 5), false, 6500},
		// The median is a real measurement: unlike the anchor it may honestly
		// LOWER an optimistic static estimate.
		{"trusted_median_lowers_static", func() routingSnapshot {
			s := median(2000, 5)
			s.prefillTPS = 4000
			return s
		}(), true, 2000},
		{"untrusted_median_falls_to_anchor", median(6500, 4), true, defaultPrefillFallbackTPS},
		{"untrusted_median_falls_to_static_when_off", median(6500, 4), false, 360},
		{"anchor_never_lowers_static", func() routingSnapshot {
			s := base
			s.prefillTPS = 9000
			return s
		}(), true, 9000},
		{"cap_applies_to_median", median(30_000, 5), false, defaultMaxPrefillTPS},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := prefillTPSForSnapshot(tc.snap, tc.recalibrate); got != tc.want {
				t.Fatalf("prefillTPSForSnapshot = %v, want %v", got, tc.want)
			}
		})
	}

	// Kill switch: the median layer vanishes; everything else is unchanged.
	t.Setenv(ttftPrefillMediansEnv, "false")
	if got := prefillTPSForSnapshot(median(6500, 50), false); got != 360 {
		t.Fatalf("kill switch off: prefillTPSForSnapshot = %v, want the static 360 exactly", got)
	}
	if got := prefillTPSForSnapshot(median(6500, 50), true); got != defaultPrefillFallbackTPS {
		t.Fatalf("kill switch off + enforce: prefillTPSForSnapshot = %v, want the anchor %v", got, defaultPrefillFallbackTPS)
	}
}

// TestPrefillMedianConvergesAcrossBoxes: several same-chip boxes that never
// reported their own measurement all estimate from the SAME fleet median — the
// transfer property that routes long prompts to (and admits them on) boxes the
// static chain would have shed.
func TestPrefillMedianConvergesAcrossBoxes(t *testing.T) {
	t.Setenv(ttftPrefillMediansEnv, "true")
	t.Setenv(ttftPrefillMinSamplesEnv, "5")
	reg := New(testLogger())
	seedPrefillMedian(reg, gptossBuild, 5, 6500)
	for i, decodeTPS := range []float64{20, 30, 90} {
		id := fmt.Sprintf("box-%d", i)
		makeSchedulerProvider(t, reg, id, gptossBuild, decodeTPS)
		reqID := fmt.Sprintf("req-%d", i)
		pr := longPromptRequest(reqID)
		p, decision := reg.ReserveProviderEx(gptossBuild, pr)
		if p == nil {
			t.Fatalf("box with decode %v: long prompt rejected, want admitted via the shared median", decodeTPS)
		}
		if decision.TTFTMs >= 5_000 {
			t.Fatalf("box with decode %v: TTFT estimate %.0fms, want ~2.1s", decodeTPS, decision.TTFTMs)
		}
		p.RemovePending(reqID)
		reg.SetProviderIdle(p.ID)
	}
}
