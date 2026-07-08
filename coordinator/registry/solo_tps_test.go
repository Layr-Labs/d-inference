package registry

import (
	"fmt"
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

func TestSoloMedianAllChipsPoolsAcrossFamilies(t *testing.T) {
	r := NewTPSRegistry()
	r.RecordSolo("model", "m1", 20)
	r.RecordSolo("model", "m1", 20)
	r.RecordSolo("model", "m4", 30)
	r.RecordSolo("model", "m4", 30)
	r.RecordSolo("model", "m4", 30)
	r.RecordSolo("other-model", "m4", 999) // different model must not pollute
	tps, n := r.SoloMedianAllChips("model")
	if tps != 30 || n != 5 {
		t.Fatalf("SoloMedianAllChips = (%v, %d), want (30, 5)", tps, n)
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
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 14},
		{Model: gptossBuild, State: "idle", NumRunning: 0, NumWaiting: 0},
	}))
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3"); n != 1 {
		t.Fatalf("solo samples after uncontended heartbeat = %d, want 1", n)
	}

	// Fully idle box: the reported EWMA is a stale decayed value with no
	// request behind it — NOT a fresh solo observation. Recording it would let
	// an idle box mint one bogus sample per heartbeat.
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "idle", ObservedDecodeTPS: 15},
	}))
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3"); n != 1 {
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
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3"); n != 1 {
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
	if _, n := reg.tpsRegistry.SoloMedian(gemmaBuild, "M3"); n != 5 {
		t.Fatalf("active-slot solo samples = %d, want 5", n)
	}
	if _, n := reg.tpsRegistry.SoloMedian(gptossBuild, "M3"); n != 0 {
		t.Fatalf("idle co-resident slot recorded %d solo samples, want 0 (stale EWMA contamination)", n)
	}
	// The load-inclusive store still sees both slots' EWMAs.
	if got := reg.tpsRegistry.Median(gptossBuild, "M3"); got != 60 {
		t.Fatalf("load-inclusive median for idle slot = %v, want 60", got)
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
	// provider's own chip family (M3) has no samples yet.
	for i, v := range []float64{16, 16, 16, 20, 20} {
		chip := "M1"
		if i >= 3 {
			chip = "M2"
		}
		reg.tpsRegistry.RecordSolo(gemmaBuild, chip, v)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 16 || !got.perModel {
		t.Fatalf("cross-chip fallback = %+v, want tps 16 (pooled median), perModel true", got)
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

func TestResolvedSoloModelTPSMinSampleFloor(t *testing.T) {
	reg := New(testLogger())
	// Floor raised to 6: five per-chip samples are NOT yet trusted.
	enablePerModelQualityCap(t, reg, "", "", "6")
	p := mixedBoxProvider(t, reg, "mixed", 93)
	for i := 0; i < 5; i++ {
		reg.tpsRegistry.RecordSolo(gemmaBuild, "M3", 14)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.tps != 93 || got.perModel {
		t.Fatalf("below min samples = %+v, want provider-level (93, perModel false)", got)
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
// carry the per-model cap alone (gemma-qat solo ≈ 14 from prod data → cap 2)
// until gated solo samples re-accumulate.
func TestSoloSeedColdStart(t *testing.T) {
	reg := New(testLogger()) // fresh registry == post-restart state
	enablePerModelQualityCap(t, reg, "gemma-4-26b-qat-4bit=14,gpt-oss-20b=30", "", "")
	p := mixedBoxProvider(t, reg, "mixed", 93)

	if got := effCapResolved(reg, p, gemmaBuild); got != 2 {
		t.Fatalf("cold-start gemma cap = %d, want 2 (seed 14 ≤ floor 15 → qc 1 × 1.2)", got)
	}
	if got := effCapResolved(reg, p, gptossBuild); got != 4 {
		t.Fatalf("cold-start gpt-oss cap = %d, want 4 (seed 30 → qc 3 → ceil(3.6))", got)
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
