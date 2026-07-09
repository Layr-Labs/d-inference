package registry

import (
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// withPrefillFallbackState snapshots and restores the package-level prefill
// fallback knobs so a test that flips mode/value/ceiling cannot leak into the
// rest of the (sequential) package suite.
func withPrefillFallbackState(t *testing.T) {
	t.Helper()
	mode, fb, ceil := prefillFallbackMode, prefillFallbackTPS, maxPrefillTPS
	t.Cleanup(func() {
		prefillFallbackMode, prefillFallbackTPS, maxPrefillTPS = mode, fb, ceil
	})
}

func TestParsePrefillFallbackMode(t *testing.T) {
	cases := map[string]PrefillFallbackMode{
		"":         PrefillFallbackOff,
		"off":      PrefillFallbackOff,
		"garbage":  PrefillFallbackOff,
		"shadow":   PrefillFallbackShadow,
		"  SHADOW": PrefillFallbackShadow,
		"enforce":  PrefillFallbackEnforce,
		"Enforce ": PrefillFallbackEnforce,
	}
	for in, want := range cases {
		if got := ParsePrefillFallbackMode(in); got != want {
			t.Errorf("ParsePrefillFallbackMode(%q) = %v, want %v", in, got, want)
		}
		if got := want.String(); ParsePrefillFallbackMode(got) != want {
			t.Errorf("round-trip String()/Parse for %v gave %q", want, got)
		}
	}
}

func TestPrefillFallbackDefaultsAndSetters(t *testing.T) {
	withPrefillFallbackState(t)

	// Defaults are the data-derived values and the safe (off) mode.
	if prefillFallbackMode != PrefillFallbackOff {
		t.Fatalf("default mode = %v, want off (behavior-neutral)", prefillFallbackMode)
	}
	if defaultPrefillFallbackTPS != 6500.0 {
		t.Fatalf("defaultPrefillFallbackTPS = %v, want 6500 (measured p50)", defaultPrefillFallbackTPS)
	}
	if defaultMaxPrefillTPS != 20000.0 {
		t.Fatalf("defaultMaxPrefillTPS = %v, want 20000 (above measured p90 17,707)", defaultMaxPrefillTPS)
	}

	SetPrefillFallbackTPS(7200)
	if PrefillFallbackTPS() != 7200 {
		t.Fatalf("PrefillFallbackTPS = %v, want 7200", PrefillFallbackTPS())
	}
	SetPrefillFallbackTPS(0) // ignored
	SetPrefillFallbackTPS(-1)
	if PrefillFallbackTPS() != 7200 {
		t.Fatalf("PrefillFallbackTPS = %v, want 7200 after ignored non-positive sets", PrefillFallbackTPS())
	}

	SetMaxPrefillTPS(18000)
	if MaxPrefillTPS() != 18000 {
		t.Fatalf("MaxPrefillTPS = %v, want 18000", MaxPrefillTPS())
	}
	SetMaxPrefillTPS(0) // ignored
	if MaxPrefillTPS() != 18000 {
		t.Fatalf("MaxPrefillTPS = %v, want 18000 after ignored zero set", MaxPrefillTPS())
	}

	SetPrefillFallbackMode(PrefillFallbackEnforce)
	if PrefillFallbackModeValue() != PrefillFallbackEnforce {
		t.Fatalf("mode = %v, want enforce", PrefillFallbackModeValue())
	}
}

// TestPrefillTPSForSnapshotRecalibration pins the core resolution helper: measured
// always wins; the recalibration only lifts (never lowers) the static estimate and
// only when BackendCapacity is present; the ceiling always caps.
func TestPrefillTPSForSnapshotRecalibration(t *testing.T) {
	withPrefillFallbackState(t)
	prefillFallbackTPS = 6500
	maxPrefillTPS = 20000

	// Measured observed prefill always wins, regardless of recalibrate.
	obs := routingSnapshot{prefillTPS: 240, observedPrefillTPS: 1800, hasBackendCapacity: true}
	if got := prefillTPSForSnapshot(obs, false); got != 1800 {
		t.Fatalf("observed (off) = %v, want 1800", got)
	}
	if got := prefillTPSForSnapshot(obs, true); got != 1800 {
		t.Fatalf("observed (recalibrate) = %v, want 1800 (measured wins)", got)
	}

	// No measurement, recalibrate OFF → legacy static estimate (the ~280 chain).
	legacy := routingSnapshot{prefillTPS: 240, hasBackendCapacity: true}
	if got := prefillTPSForSnapshot(legacy, false); got != 240 {
		t.Fatalf("legacy (off) = %v, want 240", got)
	}
	// No measurement, recalibrate ON → lifted to the data-derived fallback.
	if got := prefillTPSForSnapshot(legacy, true); got != 6500 {
		t.Fatalf("recalibrated = %v, want 6500", got)
	}

	// Recalibration is gated on BackendCapacity (a legacy provider whose TTFT is
	// never gated keeps its static estimate).
	noBC := routingSnapshot{prefillTPS: 240, hasBackendCapacity: false}
	if got := prefillTPSForSnapshot(noBC, true); got != 240 {
		t.Fatalf("recalibrate without BackendCapacity = %v, want 240 (gated)", got)
	}

	// Never LOWER a higher static estimate to the fallback.
	high := routingSnapshot{prefillTPS: 9000, hasBackendCapacity: true}
	if got := prefillTPSForSnapshot(high, true); got != 9000 {
		t.Fatalf("recalibrate with higher static = %v, want 9000 (max, never lowered)", got)
	}

	// The ceiling caps everything (e.g. an observed value above the ceiling).
	over := routingSnapshot{observedPrefillTPS: 25000, hasBackendCapacity: true}
	if got := prefillTPSForSnapshot(over, true); got != 20000 {
		t.Fatalf("over-ceiling observed = %v, want capped to 20000", got)
	}
}

// TestMaxPrefillCeilingRaiseKeepsHighObserved proves the ceiling raise: a
// genuinely-fast cold-prefill measurement that sits BETWEEN the legacy 5000 and the
// measured p90 (17,707) is now KEPT at ingest instead of being zeroed, while a true
// overflow above the new ceiling is still dropped.
func TestMaxPrefillCeilingRaiseKeepsHighObserved(t *testing.T) {
	withPrefillFallbackState(t)
	maxPrefillTPS = defaultMaxPrefillTPS // 20000

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	bc := &protocol.BackendCapacity{
		Slots: []protocol.BackendSlotCapacity{
			{Model: "p50", ObservedPrefillTPS: 6500},   // measured p50 — kept (was kept before too)
			{Model: "p90", ObservedPrefillTPS: 15000},  // between old 5000 and new ceiling — NOW kept
			{Model: "fast", ObservedPrefillTPS: 17700}, // ~p90 — NOW kept
			{Model: "overflow", ObservedPrefillTPS: 25000},
		},
	}
	clampBackendCapacity(logger, "p1", bc)

	if bc.Slots[0].ObservedPrefillTPS != 6500 {
		t.Errorf("p50 ObservedPrefillTPS = %v, want 6500 (kept)", bc.Slots[0].ObservedPrefillTPS)
	}
	if bc.Slots[1].ObservedPrefillTPS != 15000 {
		t.Errorf("p90-ish ObservedPrefillTPS = %v, want 15000 (kept under raised ceiling; was zeroed at 5000)", bc.Slots[1].ObservedPrefillTPS)
	}
	if bc.Slots[2].ObservedPrefillTPS != 17700 {
		t.Errorf("fast ObservedPrefillTPS = %v, want 17700 (kept)", bc.Slots[2].ObservedPrefillTPS)
	}
	if bc.Slots[3].ObservedPrefillTPS != 0 {
		t.Errorf("overflow ObservedPrefillTPS = %v, want 0 (above new ceiling, dropped)", bc.Slots[3].ObservedPrefillTPS)
	}
}

// makeBrokenPrefillProvider builds a healthy, model-resident provider whose static
// prefill estimate is the broken ~fleet fallback (240 tok/s), so a long prompt's
// TTFT estimate blows the gate under the legacy fallback but clears it once the
// recalibrated fallback is applied. Decode is fast so the first-decode term is
// negligible and the prefill term dominates (matching the live pathology).
func makeBrokenPrefillProvider(t *testing.T, reg *Registry, id, model string) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, model, 100) // decode 100 tok/s → 10ms first-decode
	p.mu.Lock()
	p.PrefillTPS = 240 // the broken sqrt(bandwidth)×12 ≈ fleet fallback
	p.mu.Unlock()
	return p
}

// TestLongPromptAdmittedUnderEnforceFallback is THE required regression: a
// long-prompt request that the TTFT hard gate 429s under the legacy fallback is
// ADMITTED once the recalibrated fallback is enforced — with cancels-flat safety,
// because the recalibrated estimate (~615ms prefill for 4k tokens) is well within
// the deadline rather than the legacy ~16.7s that over-shed it.
func TestLongPromptAdmittedUnderEnforceFallback(t *testing.T) {
	withPrefillFallbackState(t)
	prefillFallbackTPS = defaultPrefillFallbackTPS // 6500
	maxPrefillTPS = defaultMaxPrefillTPS           // 20000

	const (
		model     = "prefill-fallback-admit-model"
		reqPrompt = 4_000 // ≈ the live 429'd long-prompt p50 (4,009 tok)
		// Hard TTFT gate ≈ consumer ttftDeadline(4000) = 5000 + 1ms·4000.
		maxTTFTMs = 9_000.0
	)
	newReq := func(id string) *PendingRequest {
		return &PendingRequest{
			RequestID:             id,
			Model:                 model,
			EstimatedPromptTokens: reqPrompt,
			RequestedMaxTokens:    128,
			MaxTTFTMs:             maxTTFTMs,
		}
	}

	// OFF (legacy fallback ≈240 tok/s): 4000/240*1000 ≈ 16.7s ≫ 9s → 429.
	prefillFallbackMode = PrefillFallbackOff
	{
		reg := New(testLogger())
		makeBrokenPrefillProvider(t, reg, "p-off", model)
		sel, dec := reg.ReserveProviderEx(model, newReq("off"))
		if sel != nil {
			t.Fatalf("OFF: expected TTFT 429 (nil provider), got %q; decision=%+v", sel.ID, dec)
		}
		if dec.TTFTRejections != 1 {
			t.Fatalf("OFF: TTFTRejections = %d, want 1 (the only blocker is the prefill-driven TTFT gate); decision=%+v", dec.TTFTRejections, dec)
		}
		if dec.BestTTFTMs <= maxTTFTMs {
			t.Fatalf("OFF: BestTTFTMs = %v, want > %v (legacy fallback over-estimates TTFT)", dec.BestTTFTMs, maxTTFTMs)
		}
	}

	// ENFORCE (recalibrated fallback 6500 tok/s): 4000/6500*1000 ≈ 615ms ≪ 9s → admit.
	prefillFallbackMode = PrefillFallbackEnforce
	{
		reg := New(testLogger())
		p := makeBrokenPrefillProvider(t, reg, "p-enforce", model)
		sel, dec := reg.ReserveProviderEx(model, newReq("enforce"))
		if sel == nil {
			t.Fatalf("ENFORCE: expected admission, got nil; decision=%+v", dec)
		}
		if sel.ID != p.ID {
			t.Fatalf("ENFORCE: selected %q, want %q", sel.ID, p.ID)
		}
		if dec.TTFTRejections != 0 {
			t.Fatalf("ENFORCE: TTFTRejections = %d, want 0 (recalibrated prefill clears the gate)", dec.TTFTRejections)
		}
		if dec.TTFTMs > maxTTFTMs {
			t.Fatalf("ENFORCE: winning TTFTMs = %v, want <= %v", dec.TTFTMs, maxTTFTMs)
		}
	}
}

// TestPrefillFallbackShadowIsBehaviorNeutral proves shadow mode does NOT change the
// live routing decision (the same long prompt is still 429'd, byte-for-byte with
// OFF), while the recalibrated estimate the shadow measures WOULD have cleared the
// gate — exactly the projected-recovery signal the API emits before enforcing.
func TestPrefillFallbackShadowIsBehaviorNeutral(t *testing.T) {
	withPrefillFallbackState(t)
	prefillFallbackTPS = defaultPrefillFallbackTPS
	maxPrefillTPS = defaultMaxPrefillTPS

	const (
		model     = "prefill-fallback-shadow-model"
		reqPrompt = 4_000
		maxTTFTMs = 9_000.0
	)
	req := func(id string) *PendingRequest {
		return &PendingRequest{RequestID: id, Model: model, EstimatedPromptTokens: reqPrompt, RequestedMaxTokens: 128, MaxTTFTMs: maxTTFTMs}
	}

	prefillFallbackMode = PrefillFallbackShadow
	reg := New(testLogger())
	makeBrokenPrefillProvider(t, reg, "p-shadow", model)

	// Live routing in shadow mode is unchanged → still 429 (behavior-neutral).
	sel, dec := reg.ReserveProviderEx(model, req("shadow-live"))
	if sel != nil {
		t.Fatalf("SHADOW: live routing must stay 429 (behavior-neutral), got %q; decision=%+v", sel.ID, dec)
	}
	if dec.TTFTRejections != 1 {
		t.Fatalf("SHADOW: TTFTRejections = %d, want 1 (live still on legacy fallback)", dec.TTFTRejections)
	}

	// The shadow measurement (recalibration forced on) would have ADMITTED it:
	// the preflight's recalibrated best-TTFT clears the same deadline.
	recalTTFT, hasTTFT := reg.QuickCapacityCheckRecalibratedTTFT(model, reqPrompt, 128, RequestTraits{}, false)
	if !hasTTFT {
		t.Fatalf("SHADOW: recalibrated preflight produced no TTFT estimate")
	}
	if float64(recalTTFT.Milliseconds()) > maxTTFTMs {
		t.Fatalf("SHADOW: recalibrated best-TTFT = %v, want <= %v (would_admit)", recalTTFT, time.Duration(maxTTFTMs)*time.Millisecond)
	}
}
