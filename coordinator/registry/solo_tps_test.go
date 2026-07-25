package registry

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const gptossBuild = "gpt-oss-20b"

// enablePerModelQualityCap enables the quality cap exactly like
// enableQualityCap (floor 15, fallback 4, default overcommit) and pins the
// per-model solo-TPS envs — seed CSV, kill switch, min-sample floor — so
// ambient operator settings can't leak in. Package-level knobs are restored to
// defaults on cleanup so tests that never call SetQualityConcurrencyCap can't
// observe leftovers.
func enablePerModelQualityCap(t *testing.T, reg *Registry, seed, killSwitch, minSamples string) {
	t.Helper()
	t.Cleanup(func() {
		qualityCapPerModelTPS = true
		qualityCapSoloMinSamples = defaultQualityCapSoloMinSamples
		modelSoloTPSSeed = nil
		modelSoloTPSSeedFleet = nil
		qualityCapOvercommitByModel = nil
	})
	t.Setenv(modelSoloTPSSeedEnv, seed)
	t.Setenv(qualityCapPerModelTPSEnv, killSwitch)
	t.Setenv(qualityCapSoloMinSamplesEnv, minSamples)
	enableQualityCap(t, reg, "")
}

// resolveSolo evaluates the quality-cap solo-rate resolver under the locks the
// routing path holds.
func resolveSolo(reg *Registry, p *Provider, model string) soloModelTPS {
	reg.mu.RLock()
	defer reg.mu.RUnlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	return reg.resolvedSoloModelTPSLocked(p, model)
}

// effCapResolved evaluates the production per-model admission cap (solo rate
// resolved internally) under the routing-path locks — the value every
// production admission site now consumes via
// hasConcurrencyHeadroomForModelCapResolvedLocked.
func effCapResolved(reg *Registry, p *Provider, model string) int {
	reg.mu.RLock()
	defer reg.mu.RUnlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	return reg.effectiveMaxConcurrencyForModelResolvedLocked(p, model)
}

// mixedBoxProvider builds the postmortem's mixed box: registration benchmark
// taken on gpt-oss (fast), with BOTH a gpt-oss and a gemma token-budget slot.
func mixedBoxProvider(t *testing.T, reg *Registry, id string, decodeTPS float64) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, gptossBuild, decodeTPS)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 400_000,
	})
	p.mu.Unlock()
	return p
}

// --- Solo sample store ---

func TestSoloMedianReturnsMedianAndCount(t *testing.T) {
	r := NewTPSRegistry()
	for _, v := range []float64{18, 10, 14, 12, 16} {
		r.RecordSolo("model-a", "m4", v)
	}
	tps, n := r.SoloMedian("model-a", "m4")
	if tps != 14 || n != 5 {
		t.Fatalf("SoloMedian = (%v, %d), want (14, 5)", tps, n)
	}
	// The load-inclusive store must be untouched by solo recording.
	if got := r.Median("model-a", "m4"); got != 0 {
		t.Fatalf("Median = %v, want 0 (RecordSolo must not feed the load-inclusive store)", got)
	}
}

func TestSoloMedianEmptyAndInvalidSamples(t *testing.T) {
	r := NewTPSRegistry()
	if tps, n := r.SoloMedian("missing", "m4"); tps != 0 || n != 0 {
		t.Fatalf("SoloMedian(empty) = (%v, %d), want (0, 0)", tps, n)
	}
	r.RecordSolo("model", "m4", 0)
	r.RecordSolo("model", "m4", -3)
	r.RecordSolo("", "m4", 50)
	if tps, n := r.SoloMedian("model", "m4"); tps != 0 || n != 0 {
		t.Fatalf("SoloMedian(after invalid samples) = (%v, %d), want (0, 0)", tps, n)
	}
}

func TestSoloMedianFIFOCap(t *testing.T) {
	r := NewTPSRegistry()
	for i := 0; i < 50; i++ {
		r.RecordSolo("model", "chip", 100)
	}
	for i := 0; i < 10; i++ {
		r.RecordSolo("model", "chip", 200)
	}
	// 40 × 100 + 10 × 200 after FIFO eviction → median 100, count capped at 50.
	tps, n := r.SoloMedian("model", "chip")
	if tps != 100 || n != 50 {
		t.Fatalf("SoloMedian = (%v, %d), want (100, 50) after FIFO eviction", tps, n)
	}
}

// TestSoloMedianAllChipsMinOfClassMedians pins the CONSERVATIVE cross-class
// transfer: SoloMedianAllChips returns the MINIMUM of the per-class medians
// (never the pooled median, which a fast, sample-heavy class can dominate) plus
// the TOTAL sample count. A slow class (m1, median 20) and a fast class (m4,
// median 30) → the min (20), so the rate can never exceed the slowest class's
// typical rate and can never over-cap a slow box.
func TestSoloMedianAllChipsMinOfClassMedians(t *testing.T) {
	r := NewTPSRegistry()
	r.RecordSolo("model", "m1", 20)
	r.RecordSolo("model", "m1", 20)
	r.RecordSolo("model", "m4", 30)
	r.RecordSolo("model", "m4", 30)
	r.RecordSolo("model", "m4", 30)
	r.RecordSolo("other-model", "m4", 999) // different model must not pollute
	tps, n := r.SoloMedianAllChips("model")
	if tps != 20 || n != 5 {
		t.Fatalf("SoloMedianAllChips = (%v, %d), want (20, 5) — min of class medians, total count", tps, n)
	}

	// A fast class with MANY samples must not drag the min up: the pooled median
	// would be 30, but the slow class's median (12) is what a slow box can do.
	r2 := NewTPSRegistry()
	for i := 0; i < 20; i++ {
		r2.RecordSolo("m", "M4|Max", 30) // fast, sample-heavy
	}
	r2.RecordSolo("m", "M1", 12) // slow, one sample
	if tps, n := r2.SoloMedianAllChips("m"); tps != 12 || n != 21 {
		t.Fatalf("SoloMedianAllChips = (%v, %d), want (12, 21) — fast class must not dominate the min", tps, n)
	}
}

// --- Heartbeat ingest gating ---

func soloHeartbeat(slots []protocol.BackendSlotCapacity) *protocol.HeartbeatMessage {
	return &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots:         slots,
		},
	}
}

// TestSoloRecordingGatedOnUncontendedBox drives the REAL heartbeat ingest
// path: a slot EWMA becomes a solo sample only when the whole box has at most
// one running-or-waiting request (the sample-generating request itself) AND
// the slot is the one running it. Any co-resident activity — another model
// running, or waiting queue depth — disqualifies the sample, and a fully idle
// box records nothing (a decayed EWMA with no active request is not a fresh
// observation); the load-inclusive store records regardless.
func TestSoloRecordingGatedOnUncontendedBox(t *testing.T) {
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "box", gemmaBuild, 93)

	// Uncontended: gemma serving exactly the sample-generating request.
	// Solo samples are keyed by chip CLASS ("M3|Max"), not family ("M3").
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 14},
		{Model: gptossBuild, State: "idle", NumRunning: 0, NumWaiting: 0},
	}))
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3|Max"); n != 1 {
		t.Fatalf("solo samples after uncontended heartbeat = %d, want 1", n)
	}

	// Fully idle box: the reported EWMA is a stale decayed value with no
	// request behind it — NOT a fresh solo observation. Recording it would let
	// an idle box mint one bogus sample per heartbeat.
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "idle", ObservedDecodeTPS: 15},
	}))
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3|Max"); n != 1 {
		t.Fatalf("solo samples after idle heartbeat = %d, want 1 (idle EWMA must not be recorded)", n)
	}

	// Co-resident model busy → gemma's EWMA is a contended rate: NOT solo.
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 5},
		{Model: gptossBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 40},
	}))
	// Same-slot queue depth also disqualifies (batch of 2 on one model).
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 1, NumWaiting: 1, ObservedDecodeTPS: 6},
	}))
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3|Max"); n != 1 {
		t.Fatalf("solo samples after contended heartbeats = %d, want 1 (contended samples must be rejected)", n)
	}
	// The load-inclusive store keeps EVERY sample (TTFT estimation semantics).
	if got := reg.tpsRegistry.Median(gemmaBuild, "M3"); got != (6+14)/2.0 {
		t.Fatalf("load-inclusive median = %v, want 10 (all four gemma samples recorded: 14,15,5,6)", got)
	}
}

// TestSoloRecordingOnlySamplesActiveSlot is the idle-co-resident contamination
// regression: with model A running the box's ONE active request, model B's
// idle slot keeps re-reporting its stale decayed EWMA in every heartbeat.
// Only A may be sampled — otherwise B accumulates one duplicate "solo"
// sample per ~30s heartbeat from a single long-past observation, reaches the
// min-sample trust floor without any real measurement, and B's quality cap is
// then derived from a rate no request produced.
func TestSoloRecordingOnlySamplesActiveSlot(t *testing.T) {
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "box", gemmaBuild, 93)

	for i := 0; i < 5; i++ {
		reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
			{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 14},
			{Model: gptossBuild, State: "idle", ObservedDecodeTPS: 60}, // stale EWMA, no request
		}))
	}
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3|Max"); n != 5 {
		t.Fatalf("active-slot solo samples = %d, want 5", n)
	}
	if _, n := reg.tpsRegistry.SoloMedian(gptossBuild, "M3|Max"); n != 0 {
		t.Fatalf("idle co-resident slot recorded %d solo samples, want 0 (stale EWMA contamination)", n)
	}
	// The load-inclusive store still sees both slots' EWMAs.
	if got := reg.tpsRegistry.Median(gptossBuild, "M3"); got != 60 {
		t.Fatalf("load-inclusive median for idle slot = %v, want 60", got)
	}
}

// TestSoloRecordingRequiresRunningDecode is the queued-but-not-running
// regression (Finding 3 of the final round): a box with one QUEUED request and
// no running decode is box-wide uncontended (soloEligible), and the owning slot
// has NumWaiting > 0 — but its ObservedDecodeTPS is a retained EWMA with no
// running decode behind it. The prior round's NumRunning+NumWaiting > 0 gate
// would mint that stale EWMA as a fresh solo sample every heartbeat; the
// tightened NumRunning > 0 gate must not. A running-and-uncontended heartbeat
// still records. Fails without the NumRunning > 0 gate in the heartbeat ingest.
func TestSoloRecordingRequiresRunningDecode(t *testing.T) {
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "box", gemmaBuild, 93)

	// Queued but NOT decoding: NumRunning 0 / NumWaiting 1. Box-wide load = 1
	// (uncontended), but observed_decode_tps is a stale retained EWMA — no
	// running request produced it, so it must NOT be sampled.
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 0, NumWaiting: 1, ObservedDecodeTPS: 14},
	}))
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3|Max"); n != 0 {
		t.Fatalf("solo samples after queued-but-not-running heartbeat = %d, want 0 (stale EWMA, no running decode)", n)
	}

	// Running and uncontended: NumRunning 1 / NumWaiting 0 → a real solo sample.
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 1, NumWaiting: 0, ObservedDecodeTPS: 12},
	}))
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3|Max"); n != 1 {
		t.Fatalf("solo samples after running-uncontended heartbeat = %d, want 1", n)
	}
	// The load-inclusive store records BOTH heartbeats' EWMAs regardless.
	if got := reg.tpsRegistry.Median(gemmaBuild, "M3"); got != (12+14)/2.0 {
		t.Fatalf("load-inclusive median = %v, want 13 (both EWMAs recorded: 14, 12)", got)
	}
}

// --- Resolver fallback chain ---

func TestResolvedSoloModelTPSFallbackChain(t *testing.T) {
	reg := New(testLogger())
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14", "", "")
	p := mixedBoxProvider(t, reg, "mixed", 93) // ChipFamily "M3"

	// (c) seed only — no solo samples anywhere.
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 14 || !got.perModel {
		t.Fatalf("seed fallback = %+v, want tps 14, perModel true", got)
	}

	// (b) cross-chip pooled median once total n ≥ floor (5), even though the
	// provider's own chip family (M3) has no samples yet. The configured seed
	// remains an upper bound for an unsampled class, so the faster pooled median
	// cannot widen this provider's cold-start cap.
	for i, v := range []float64{16, 16, 16, 20, 20} {
		chip := "M1"
		if i >= 3 {
			chip = "M2"
		}
		reg.tpsRegistry.RecordSolo(gemmaBuild, chip, v)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 14 || !got.perModel {
		t.Fatalf("cross-chip fallback = %+v, want seed-bounded tps 14 (pooled median 16), perModel true", got)
	}

	// (a) per-(model, chip) median wins over cross-chip and seed once trusted.
	for _, v := range []float64{10, 12, 12, 12, 30} {
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M3", v)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 12 || !got.perModel {
		t.Fatalf("per-chip solo median = %+v, want tps 12, perModel true", got)
	}

	// (d) a model with no solo data and no seed falls back to the provider-level
	// rate (the registration benchmark).
	if got := resolveSolo(reg, p, gptossBuild); got.tps != 93 || got.perModel {
		t.Fatalf("provider-level fallback = %+v, want tps 93, perModel false", got)
	}
}

// setChipClass overrides a provider's chip family/tier so tests can drive the
// class-keyed solo resolver (chipClassKey = family|tier).
func setChipClass(p *Provider, family, tier string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.Hardware.ChipFamily = family
	p.Hardware.ChipTier = tier
}

// TestSoloResolverChipClassKeying is the correctness-critical safety test for
// Fix 2: solo caps are keyed by chip CLASS (family+tier), and the cross-class
// fallback is the MIN of per-class medians. Together these guarantee the
// resolver never hands a slow box a rate faster than its own class demonstrated
// — the over-admission that collapses a slow box under load.
func TestSoloResolverChipClassKeying(t *testing.T) {
	// (a) same-class primary lookup applies: an M3|Max box uses M3|Max samples.
	t.Run("same_class_primary", func(t *testing.T) {
		reg := New(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := mixedBoxProvider(t, reg, "m3max", 93)
		setChipClass(p, "M3", "Max")
		for _, v := range []float64{10, 12, 12, 12, 30} { // median 12
			reg.tpsRegistry.RecordSolo(gemmaBuild, "M3|Max", v)
		}
		if got := resolveSolo(reg, p, gemmaBuild); got.tps != 12 || !got.perModel {
			t.Fatalf("same-class resolver = %+v, want tps 12, perModel true", got)
		}
	})

	// (b) cross-tier isolation: an M4|Pro box must NOT inherit the fast M4|Max
	// tier's rate. With family-only keying both tiers pooled under "M4" and the
	// Pro box got the Max rate; class keying keeps them separate, so the Pro box
	// resolves to its OWN slower median.
	t.Run("cross_tier_isolation", func(t *testing.T) {
		reg := New(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := mixedBoxProvider(t, reg, "m4pro", 93)
		setChipClass(p, "M4", "Pro")
		for i := 0; i < 5; i++ {
			reg.tpsRegistry.RecordSolo(gemmaBuild, "M4|Max", 40) // fast tier
		}
		for _, v := range []float64{14, 15, 15, 15, 16} { // slow tier, median 15
			reg.tpsRegistry.RecordSolo(gemmaBuild, "M4|Pro", v)
		}
		if got := resolveSolo(reg, p, gemmaBuild); got.tps != 15 {
			t.Fatalf("M4|Pro resolved %v, want 15 (its own class median), NOT the M4|Max 40", got.tps)
		}
	})

	// (c) conservative cross-class fallback: a box whose own class has no samples
	// falls to SoloMedianAllChips, which returns the MIN of class medians — the
	// slow class (10), never the fast one (40). A slow box can never be over-capped.
	t.Run("conservative_cross_class_fallback", func(t *testing.T) {
		reg := New(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := mixedBoxProvider(t, reg, "m2max", 93)
		setChipClass(p, "M2", "Max") // no M2|Max samples exist
		for i := 0; i < 5; i++ {
			reg.tpsRegistry.RecordSolo(gemmaBuild, "M4|Max", 40) // fast class
		}
		for i := 0; i < 5; i++ {
			reg.tpsRegistry.RecordSolo(gemmaBuild, "M1", 10) // slow class
		}
		if got := resolveSolo(reg, p, gemmaBuild); got.tps != 10 || !got.perModel {
			t.Fatalf("cross-class fallback = %+v, want tps 10 (min of class medians), NOT the fast 40", got)
		}
	})

	// (d) cold-start safety: a cold-class box with only FASTER classes present
	// still gets the conservative min of those class medians (25, the slower of
	// the two), never the fastest (40).
	t.Run("cold_class_conservative_min", func(t *testing.T) {
		reg := New(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := mixedBoxProvider(t, reg, "m2ultra", 93)
		setChipClass(p, "M2", "Ultra") // no M2|Ultra samples exist
		for i := 0; i < 5; i++ {
			reg.tpsRegistry.RecordSolo(gemmaBuild, "M4|Max", 40) // fastest
		}
		for i := 0; i < 5; i++ {
			reg.tpsRegistry.RecordSolo(gemmaBuild, "M3|Max", 25) // slower of the two
		}
		if got := resolveSolo(reg, p, gemmaBuild); got.tps != 25 {
			t.Fatalf("cold-class resolver = %v, want 25 (conservative min), never the fastest 40", got.tps)
		}
	})
}

// TestSoloClassKeyingEndToEndNoCrossTierOverCap drives the REAL heartbeat
// ingest so both the ingest key (registry.go) and the resolver key
// (concurrency_cap.go) are exercised: two same-family boxes of different tiers
// (M4 Max fast, M4 Pro slow) serving gemma solo. With chip-CLASS keying the
// slow box's cap comes from its OWN 14 tok/s (→ cap 2) while the fast box keeps
// its wide cap from 40 tok/s. With family-only keying both tiers pool under
// "M4" and the slow box's cap inflates from the fast box's samples — the exact
// cross-tier over-admission this fix prevents. Reverting either the ingest or
// the resolver keying trips one of the two assertions.
func TestSoloClassKeyingEndToEndNoCrossTierOverCap(t *testing.T) {
	reg := New(testLogger())
	enablePerModelQualityCap(t, reg, "", "", "5")

	mk := func(id, family, tier string) *Provider {
		p := makeSchedulerProvider(t, reg, id, gemmaBuild, 93)
		p.mu.Lock()
		p.Hardware.ChipFamily = family
		p.Hardware.ChipTier = tier
		p.mu.Unlock()
		return p
	}
	fast := mk("fast", "M4", "Max")
	slow := mk("slow", "M4", "Pro")

	// Five uncontended solo heartbeats each: fast decodes gemma at 40, slow at
	// 14. One running gemma request per heartbeat gates the sample in.
	for i := 0; i < 5; i++ {
		reg.Heartbeat("fast", soloHeartbeat([]protocol.BackendSlotCapacity{
			{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 40},
		}))
		reg.Heartbeat("slow", soloHeartbeat([]protocol.BackendSlotCapacity{
			{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 14},
		}))
	}

	if got := effCapResolved(reg, slow, gemmaBuild); got != 2 {
		t.Fatalf("slow (M4|Pro) gemma cap = %d, want 2 (its own 14 tok/s); family keying inflates it from the fast M4|Max box", got)
	}
	if got := effCapResolved(reg, fast, gemmaBuild); got <= 2 {
		t.Fatalf("fast (M4|Max) gemma cap = %d, want wide (its own 40 tok/s), not dragged down cross-tier", got)
	}
}

// TestResolvedSoloModelTPSMinSampleFloor pins what the min-sample floor now
// selects BETWEEN, and that the terminal provider-level fallback is still
// wired.
//
// The floor used to be the boundary between a per-model rate and the
// provider-level one. It no longer is: below the floor the resolver prefers
// the under-sampled — but still solo-gated and still per-model — measured
// median over resolvedDecodeTPS's model-AGNOSTIC sqrt-bandwidth proxy (see
// resolvedSoloModelTPSLocked). Here that difference is the whole postmortem
// layer-6 failure in one line: 14 tok/s is gemma's own measured rate, 93 is
// the mixed box's registration benchmark taken on gpt-oss. Five gemma samples
// are better evidence about gemma than a fast benchmark of a different model.
//
// What the floor still decides is the TRUST TIER — authoritative, or a
// fallback ranked below the configured seed — and the provider-level rate is
// now reached only when the model has NO measurement at all.
func TestResolvedSoloModelTPSMinSampleFloor(t *testing.T) {
	reg := New(testLogger())
	// Floor raised to 6: five samples are NOT yet the trusted tier.
	enablePerModelQualityCap(t, reg, "", "", "6")
	p := mixedBoxProvider(t, reg, "mixed", 93)

	// No measurement at all — the terminal provider-level fallback. This is
	// the only remaining route to resolvedDecodeTPS(p), so it is pinned here.
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 93 || got.perModel {
		t.Fatalf("no samples = %+v, want the provider-level fallback (93, perModel false)", got)
	}

	for range 5 {
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M3", 14)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 14 || !got.perModel {
		t.Fatalf("below min samples = %+v, want the under-sampled measured rate (14, perModel true), not the provider-level 93", got)
	}
	reg.tpsRegistry.RecordSolo(gemmaBuild, "M3", 14)
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 14 || !got.perModel {
		t.Fatalf("at min samples = %+v, want (14, perModel true)", got)
	}
}

func TestResolvedSoloModelTPSKillSwitch(t *testing.T) {
	reg := New(testLogger())
	// Kill switch OFF: solo medians and seed present but must be ignored —
	// resolvedDecodeTPS(p) exactly, at every consumer.
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14", "false", "")
	p := mixedBoxProvider(t, reg, "mixed", 93)
	for i := 0; i < 10; i++ {
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M3", 14)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 93 || got.perModel {
		t.Fatalf("kill switch off: resolver = %+v, want provider-level (93, perModel false)", got)
	}
}

// --- Seed parsing ---

func TestParseModelFloatMapSeedEntries(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want map[string]float64
	}{
		{"empty", "", nil},
		{"single", "gemma-4-26b-qat-4bit=14", map[string]float64{"gemma-4-26b-qat-4bit": 14}},
		{"multi_with_spaces", " gemma-4-26b-qat-4bit=14 , gpt-oss-20b=30 ", map[string]float64{"gemma-4-26b-qat-4bit": 14, "gpt-oss-20b": 30}},
		{"uppercase_key_lowered", "GPT-OSS-20B=30", map[string]float64{"gpt-oss-20b": 30}},
		{"bad_entries_skipped", "bogus,=3,x=,gemma=abc,gemma=0,gemma=-2,good=14.5", map[string]float64{"good": 14.5}},
		// strconv.ParseFloat accepts NaN/±Inf spellings; NaN in particular
		// slips past a naive v <= 0 filter (NaN comparisons are always false)
		// and would drive the cap math to an implementation-defined integer.
		{"non_finite_skipped", "a=NaN,b=+Inf,c=Inf,d=-Inf,e=Infinity,good=2", map[string]float64{"good": 2}},
		{"all_invalid", "bogus,=3,x=abc", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseModelFloatMap(tc.raw)
			if len(got) != len(tc.want) {
				t.Fatalf("parseModelFloatMap(%q) = %v, want %v", tc.raw, got, tc.want)
			}
			for k, v := range tc.want {
				if got[k] != v {
					t.Fatalf("parseModelFloatMap(%q)[%q] = %v, want %v", tc.raw, k, got[k], v)
				}
			}
		})
	}
}

// TestSoloSeedColdStart is the restart scenario: the TPS registry is in-memory
// and wiped by a coordinator restart, so on a fresh registry the seed env must
// carry the per-model cap alone until gated solo samples re-accumulate. The
// gemma seed (14, at or under the 15 floor) pins to 2 at any measured k; the
// gpt-oss cap is k-derived (see the helpers in concurrency_cap_test.go).
func TestSoloSeedColdStart(t *testing.T) {
	reg := New(testLogger()) // fresh registry == post-restart state
	enablePerModelQualityCap(t, reg, "gemma-4-26b-qat-4bit=14,gpt-oss-20b=30", "", "")
	p := mixedBoxProvider(t, reg, "mixed", 93)

	if got := effCapResolved(reg, p, gemmaBuild); got != 2 {
		t.Fatalf("cold-start gemma cap = %d, want 2 (seed 14 ≤ floor 15 → quality batch 1 × 1.2)", got)
	}
	wantGptoss := wantQualityCap(30, 15, 24, defaultQualityCapOvercommit)
	if got := effCapResolved(reg, p, gptossBuild); got != wantGptoss {
		t.Fatalf("cold-start gpt-oss cap = %d, want %d (seed 30 at k=%.2f × 1.2)", got, wantGptoss, effectiveTPSLoadFactor)
	}
}

// prodSoloTPSSeed returns the EIGENINFERENCE_MODEL_SOLO_TPS_SEED value shipped
// in deploy/environments/prod.env. Reading the real file rather than pinning a
// copy is deliberate: the P1 this suite defends is a bad VALUE in that file,
// so a test asserting against a hand-copied CSV would keep passing while prod
// regressed. The repository root is located by walking up for the file itself
// (the Go module root is coordinator/, one level below it).
func prodSoloTPSSeed(t *testing.T) string {
	t.Helper()
	const rel = "deploy/environments/prod.env"
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	var path string
	for {
		candidate := filepath.Join(dir, rel)
		if _, statErr := os.Stat(candidate); statErr == nil {
			path = candidate
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("no ancestor of %q contains %s", dir, rel)
		}
		dir = parent
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	const key = modelSoloTPSSeedEnv + "="
	for _, line := range strings.Split(string(raw), "\n") {
		if after, ok := strings.CutPrefix(strings.TrimSpace(line), key); ok {
			return after
		}
	}
	t.Fatalf("%s carries no %s line", path, modelSoloTPSSeedEnv)
	return ""
}

// classProvider is a single-model provider on a named chip class whose slot
// reports the production MaxConcurrency of 8 — the `base` operand of the cap's
// MIN, so the numbers here are the ones prod actually grants.
func classProvider(t *testing.T, reg *Registry, id, model, family, tier string) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, model, 0) // no registration benchmark
	p.mu.Lock()
	p.Hardware.ChipName = family + " " + tier
	p.Hardware.ChipFamily = family
	p.Hardware.ChipTier = tier
	p.BackendCapacity.Slots[0].MaxConcurrency = 8
	p.mu.Unlock()
	return p
}

// TestSoloSeedIsChipClassScoped is the P1 guard: the 70 tok/s cold-start seed
// was MEASURED on an M4 Max, and applying it fleet-wide hands an M1 Pro — which
// decodes gemma at 10-18 tok/s — a cap of 8, projecting ~3.4 tok/s per request
// at that batch against a 15 tok/s floor. The seed the coordinator resolves
// must therefore depend on the provider's chip CLASS, and every class the
// operator did not name must land on the conservative floor.
//
// It runs against the CSV actually shipped in prod.env, so re-broadening the
// seed there fails here.
func TestSoloSeedIsChipClassScoped(t *testing.T) {
	seed := prodSoloTPSSeed(t)
	reg := New(testLogger()) // fresh registry == post-restart, no solo samples
	enablePerModelQualityCap(t, reg, seed, "", "")

	cases := []struct {
		name     string
		family   string
		tier     string
		wantTPS  float64
		wantCap  int
		measured bool // the class the 70 tok/s number came from
	}{
		{name: "m4_max_measured_class", family: "M4", tier: "Max", wantTPS: 70, wantCap: 8, measured: true},
		{name: "m1_pro_slower_class", family: "M1", tier: "Pro", wantTPS: 14, wantCap: 2},
		{name: "m4_pro_same_family_slower_tier", family: "M4", tier: "Pro", wantTPS: 14, wantCap: 2},
		{name: "unrecognized_chip", family: "Unknown", tier: "Unknown", wantTPS: 14, wantCap: 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := classProvider(t, reg, "box-"+tc.name, gemmaBuild, tc.family, tc.tier)
			got := resolveSolo(reg, p, gemmaBuild)
			if got.tps != tc.wantTPS || !got.perModel {
				t.Fatalf("%s|%s resolved %+v, want tps %v perModel true",
					tc.family, tc.tier, got, tc.wantTPS)
			}
			if cap := effCapResolved(reg, p, gemmaBuild); cap != tc.wantCap {
				t.Fatalf("%s|%s cap = %d, want %d", tc.family, tc.tier, cap, tc.wantCap)
			}
			if !tc.measured && got.tps >= 70 {
				t.Fatalf("%s|%s inherited the M4 Max seed (%v tok/s) — the exact over-admission this fix prevents",
					tc.family, tc.tier, got.tps)
			}
		})
	}
}

// TestSoloSeedNoMorePermissiveOnSlowerClasses is the other half of the P1: the
// scoped seed must not merely differ from the fleet-wide one, it must be
// TIGHTER everywhere except the class the fast rate was measured on.
//
// The same fleet is walked through three seed configurations — none at all
// (the pre-seed provider-level chain), the fleet-wide 70 this PR originally
// shipped, and the chip-class-scoped CSV now in prod.env — and every class
// other than M4|Max must come out no more permissive than either baseline.
// Note the pre-seed cap is the provider's REPORTED 8, not a proxy-derived
// number: with no registration benchmark and a non-dedicated model,
// effectiveMaxConcurrencyForModelRateLocked refuses to cap from the
// model-agnostic sqrt-bandwidth rate at all and returns base.
func TestSoloSeedNoMorePermissiveOnSlowerClasses(t *testing.T) {
	classes := [][2]string{{"M4", "Max"}, {"M1", "Pro"}, {"M4", "Pro"}, {"M2", "Max"}, {"Unknown", "Unknown"}}
	capsFor := func(seed string) map[string]int {
		reg := New(testLogger())
		enablePerModelQualityCap(t, reg, seed, "", "")
		out := make(map[string]int, len(classes))
		for _, c := range classes {
			key := c[0] + "|" + c[1]
			p := classProvider(t, reg, "box-"+key+"-"+seed, gemmaBuild, c[0], c[1])
			out[key] = effCapResolved(reg, p, gemmaBuild)
		}
		return out
	}

	noSeed := capsFor("")
	fleetWide := capsFor(gemmaBuild + "=70") // what this PR shipped
	scoped := capsFor(prodSoloTPSSeed(t))

	for _, c := range classes {
		key := c[0] + "|" + c[1]
		if key == "M4|Max" {
			// The measured class must KEEP its cap; scoping is not a
			// fleet-wide retreat, it is a scope correction.
			if scoped[key] != fleetWide[key] {
				t.Fatalf("M4|Max cap %d != fleet-wide %d — the measured class lost its seed", scoped[key], fleetWide[key])
			}
			continue
		}
		if scoped[key] > fleetWide[key] || scoped[key] > noSeed[key] {
			t.Fatalf("%s cap %d is more permissive than a baseline (fleet-wide-70 %d, no-seed %d)",
				key, scoped[key], fleetWide[key], noSeed[key])
		}
		if scoped[key] >= fleetWide[key] {
			t.Fatalf("%s cap %d did not TIGHTEN against the fleet-wide-70 baseline %d — the fix is inert on this class",
				key, scoped[key], fleetWide[key])
		}
	}
}

// TestSoloSeedFleetFallbackClampedToSlowestNamedClass pins the structural half
// of the fix. Scoping alone still lets an operator write a fast unqualified
// value beside a slow class entry and re-create the bug; the unqualified entry
// is therefore clamped to the slowest class named for that model, so an
// unnamed class can never out-rank the slowest one that WAS named — the same
// min-of-classes invariant SoloMedianAllChips enforces for measured medians.
func TestSoloSeedFleetFallbackClampedToSlowestNamedClass(t *testing.T) {
	reg := New(testLogger())
	// Operator error: a 70 fleet-wide value alongside a 14 tok/s M1 Pro entry.
	enablePerModelQualityCap(t, reg,
		gemmaBuild+"=70,"+gemmaBuild+"@M1|Pro=14,"+gemmaBuild+"@M4|Max=70", "", "")

	// The named slow class gets its own rate.
	slow := classProvider(t, reg, "m1pro", gemmaBuild, "M1", "Pro")
	if got := resolveSolo(reg, slow, gemmaBuild); got.tps != 14 {
		t.Fatalf("M1|Pro resolved %v, want its own 14", got.tps)
	}
	// An UNNAMED class takes the fleet-wide entry clamped down to 14, not 70.
	unnamed := classProvider(t, reg, "m2max", gemmaBuild, "M2", "Max")
	if got := resolveSolo(reg, unnamed, gemmaBuild); got.tps != 14 {
		t.Fatalf("unnamed M2|Max resolved %v, want the clamped 14 — an unnamed class must never out-rank the slowest named one", got.tps)
	}
	named := classProvider(t, reg, "m4max", gemmaBuild, "M4", "Max")
	if got := resolveSolo(reg, named, gemmaBuild); got.tps != 70 {
		t.Fatalf("M4|Max resolved %v, want its own 70 — the clamp must not touch a named class", got.tps)
	}
}

// TestSoloSeedClassEntryYieldsToMeasuredSamples: a class-qualified seed is a
// COLD-START estimate, not a pin. Once the provider's own class has enough
// gated solo samples the median wins, exactly as an unqualified seed does.
func TestSoloSeedClassEntryYieldsToMeasuredSamples(t *testing.T) {
	reg := New(testLogger())
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14,"+gemmaBuild+"@M4|Max=70", "", "5")
	p := classProvider(t, reg, "m4max", gemmaBuild, "M4", "Max")
	for _, v := range []float64{30, 32, 33, 34, 36} { // median 33
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M4|Max", v)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 33 {
		t.Fatalf("resolved %v, want the measured 33 — the class seed must not outrank its own class's samples", got.tps)
	}
}

// TestSoloSeedFleetFallbacksParsing covers the clamp table directly, including
// the degenerate shapes parseModelFloatMap can hand it.
func TestSoloSeedFleetFallbacksParsing(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want map[string]float64
	}{
		{name: "no_class_entries_passthrough", raw: "a=20,b=30", want: map[string]float64{"a": 20, "b": 30}},
		{name: "clamped_to_slowest_class", raw: "a=70,a@m4|max=70,a@m1|pro=14", want: map[string]float64{"a": 14}},
		{name: "fleet_already_below_classes", raw: "a=9,a@m4|max=70", want: map[string]float64{"a": 9}},
		{name: "class_only_has_no_fleet_entry", raw: "a@m4|max=70", want: nil},
		{name: "clamp_is_per_model", raw: "a=70,b=70,a@m1|pro=14", want: map[string]float64{"a": 14, "b": 70}},
		{name: "empty", raw: "", want: nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := soloSeedFleetFallbacks(parseModelFloatMap(tc.raw))
			if len(got) != len(tc.want) {
				t.Fatalf("soloSeedFleetFallbacks(%q) = %v, want %v", tc.raw, got, tc.want)
			}
			for k, v := range tc.want {
				if got[k] != v {
					t.Fatalf("soloSeedFleetFallbacks(%q)[%q] = %v, want %v", tc.raw, k, got[k], v)
				}
			}
		})
	}
}

// --- Warm-pool consistency ---

// TestWarmPoolSnapshotDecodeSampleUsesSoloResolver: the warm-pool fleet
// snapshot's decode samples (→ soloDecodeTPS → warm-target quality
// concurrency) must come from the SAME solo resolver as the admission cap —
// here the gemma solo median (14) — not the collapsed under-load slot EWMA
// (2.6) and not the provider-level benchmark (93). Otherwise admission would
// cap a box at 2 while the warm-pool controller plans capacity as if it could
// take 19.
func TestWarmPoolSnapshotDecodeSampleUsesSoloResolver(t *testing.T) {
	reg := New(testLogger())
	enablePerModelQualityCap(t, reg, "", "", "")
	p := makeSchedulerProvider(t, reg, "gemma-box", gemmaBuild, 93)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 2.6 // collapsed contended EWMA
	p.mu.Unlock()
	for i := 0; i < 5; i++ {
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M3", 14)
	}

	snap := reg.warmPoolFleetSnapshot(time.Now())[gemmaBuild]
	if snap.soloDecodeTPS != 14 {
		t.Fatalf("warm-pool soloDecodeTPS = %v, want 14 (solo median; EWMA 2.6 and benchmark 93 must not feed the warm target)", snap.soloDecodeTPS)
	}
	if snap.serviceDecodeTPS != 2.6 {
		t.Fatalf("warm-pool serviceDecodeTPS = %v, want observed 2.6 (E[S] keeps load-inclusive semantics)", snap.serviceDecodeTPS)
	}
}

// TestSoloResolverConvergesAcrossManyBoxes is a small sanity spread: several
// mixed boxes with different provider-level benchmarks all resolve the SAME
// per-model rate once the solo median is trusted — the property that makes
// caps chip-honest instead of benchmark-inherited.
func TestSoloResolverConvergesAcrossManyBoxes(t *testing.T) {
	reg := New(testLogger())
	enablePerModelQualityCap(t, reg, "", "", "")
	for i := 0; i < 5; i++ {
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M3", 14)
	}
	for i, bench := range []float64{58, 73, 93} {
		p := mixedBoxProvider(t, reg, fmt.Sprintf("box-%d", i), bench)
		if got := effCapResolved(reg, p, gemmaBuild); got != 2 {
			t.Fatalf("box benchmarked %v tok/s: gemma cap = %d, want 2 regardless of the provider-level benchmark", bench, got)
		}
	}
}
