package registry_test

import (
	"fmt"
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// TestQualityCapPrefersMeasuredSoloRateOverProxyAndSeed pins the evidence used
// for a provider with no registration benchmark and a reported limit of 8.
// Without model-specific evidence the hardware proxy cannot tighten that limit.
// A seed or solo-gated measurement can, and even an under-sampled measurement
// outranks a seed. The trust floor still selects a well-sampled median first.
//
// The Swift provider reports its per-model EWMA in observed_decode_tps on
// heartbeats, and uncontended observations become solo samples. The measured
// ~99.5 tok/s clears the quality threshold for 8, unlike a stale 14 tok/s seed.
func TestQualityCapPrefersMeasuredSoloRateOverProxyAndSeed(t *testing.T) {
	const floor = 15.0
	const base = 8
	// The CBv2 v2-paged B=1 per-request decode rate for gemma-4-26b-qat-4bit on
	// an M4 Max — the shipping engine's own, conservative number (eager measures
	// 101.8):
	// libs/mlx-swift-lm/benchmarks/reports/gemma4-26b-qat4bit-paged-gate-2026-07-09.md
	const measuredGemmaSoloTPS = 99.5
	// A stale seed below the decode floor must yield to measured evidence.
	const starvedSeedTPS = 14.0

	// threshold is the solo rate at which a provider reporting `base` is granted
	// all of it, derived from (floor, k, overcommit) rather than hard-coded.
	threshold := soloTPSForCap(floor, base, defaultQualityCapOvercommit)

	// prodBox has no registration benchmark and reports concurrency of 8.
	prodBox := func(t *testing.T, reg *qualityFixture) *production.Provider {
		p := qualityProvider(t, reg, "prod-box", gemmaBuild, 0)
		p.Mu().Lock()
		p.BackendCapacity.Slots[0].MaxConcurrency = base
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
		p.Mu().Unlock()
		return p
	}
	// slot is the heartbeat slot the provider sends. observedTPS <= 0 models a
	// provider that has completed no request: observedDecodeTpsEwma is still 0,
	// `observed_decode_tps` is omitempty, so the field is absent on the wire.
	slot := func(observedTPS float64, numRunning int) protocol.BackendSlotCapacity {
		return protocol.BackendSlotCapacity{
			Model:                gemmaBuild,
			State:                "running",
			NumRunning:           numRunning,
			MaxConcurrency:       base,
			ActiveTokenBudgetMax: 500_000,
			ObservedDecodeTPS:    observedTPS,
		}
	}
	// observe drives the REAL heartbeat ingest path n times — the same
	// soloSampleEligible + NumRunning > 0 gate production uses, not a direct
	// tpsRegistry poke.
	observe := func(reg *qualityFixture,

		n int, tps float64) {
		for range n {
			reg.Heartbeat("prod-box", soloHeartbeat([]protocol.BackendSlotCapacity{slot(tps, 1)}))
		}
	}

	// --- The arithmetic the fix has to clear ---------------------------------
	//
	// effectiveTPSLoadFactor was re-fitted 0.27 -> 0.39, which RAISES the solo
	// rate needed for cap 8 from ~39.3 to ~50.1 tok/s. Assert the derived
	// threshold really is that, then assert the measured rate clears it with
	// close to 2x margin — the fix must not be resting on a rounding edge.
	t.Run("measured_rate_clears_the_refitted_threshold_with_margin", func(t *testing.T) {
		if effectiveTPSLoadFactor != 0.39 {
			t.Fatalf("k = %.2f, expected the re-fitted 0.39 — the margins below are stated against it", effectiveTPSLoadFactor)
		}
		if math.Abs(threshold-50.1) > 0.5 {
			t.Fatalf("derived cap-8 threshold = %.2f tok/s, expected ~50.1 at floor %.0f / k %.2f / overcommit %.1f",
				threshold, floor, effectiveTPSLoadFactor, defaultQualityCapOvercommit)
		}
		if margin := measuredGemmaSoloTPS / threshold; margin < 1.9 {
			t.Fatalf("measured %.1f tok/s is only %.2fx the %.2f tok/s cap-8 threshold — want >= 1.9x real margin",
				measuredGemmaSoloTPS, margin, threshold)
		}
		// Granted on QUALITY, not bought with the overcommit allowance: the
		// strict quality batch alone reaches base, and the projected
		// per-request rate at B=8 stays at or above the floor.
		if qc := strictQualityBatch(measuredGemmaSoloTPS, floor, effectiveTPSLoadFactor, base); qc != base {
			t.Fatalf("strict quality batch at the measured rate = %d, want %d — cap 8 must not depend on overcommit rounding", qc, base)
		}
		if projected := measuredGemmaSoloTPS / (1 + effectiveTPSLoadFactor*base); projected < floor {
			t.Fatalf("projected per-request decode at B=8 is %.2f tok/s, below the %.0f floor", projected, floor)
		}
	})

	// --- Cold start: a provider that has served nothing ----------------------
	//
	// With no observed_decode_tps, no sample is ingested and the resolver uses
	// the hardware proxy. That proxy alone must not restrict the reported cap.
	t.Run("cold_start_without_evidence_preserves_reported_cap", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")
		reg.Heartbeat("prod-box", soloHeartbeat([]protocol.BackendSlotCapacity{slot(0, 0)}))

		if _, n := reg.throughput.SoloMedian(gemmaBuild, quality.ChipClass(p.Hardware)); n != 0 {
			t.Fatalf("solo samples from a provider that reported no rate = %d, want 0", n)
		}
		rate := resolveSolo(reg, p, gemmaBuild)
		if rate.PerModel {
			t.Fatalf("cold start resolved a per-model rate (%.2f) with no measurement and no seed", rate.TPS)
		}
		if rate.TPS !=
			providerDecodeFallback(p) {
			t.Fatalf("cold-start rate = %.2f, want the provider-level proxy %.2f", rate.TPS, providerDecodeFallback(p))
		}
		if got := effCapResolved(reg, p, gemmaBuild); got != base {
			t.Fatalf("cold-start cap = %d, want reported %d without benchmark or model evidence", got, base)
		}
	})

	// --- The fix: one measured, solo-gated sample is enough ------------------
	t.Run("one_measured_sample_below_sample_floor_is_used", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")

		if got := effCapResolved(reg, p, gemmaBuild); got != base {
			t.Fatalf("before any measurement the cap is %d, want reported %d", got, base)
		}

		observe(reg, 1, measuredGemmaSoloTPS)

		_, n := reg.throughput.SoloMedian(gemmaBuild, quality.ChipClass(p.Hardware))
		if n != 1 {
			t.Fatalf("solo samples = %d, want exactly 1", n)
		}
		if n >= reg.policy.MinSamples() {
			t.Fatalf("test is not exercising the under-sampled path: %d samples meets the %d floor", n, reg.policy.MinSamples())
		}
		rate := resolveSolo(reg, p, gemmaBuild)
		if !rate.PerModel || math.Abs(rate.TPS-measuredGemmaSoloTPS) > 1e-9 {
			t.Fatalf("resolved rate = %+v, want the measured %.1f tok/s tagged per-model", rate, measuredGemmaSoloTPS)
		}
		if got := effCapResolved(reg, p, gemmaBuild); got != base {
			t.Fatalf("cap = %d, want %d: one solo-gated measurement of the real rate must beat the model-agnostic proxy", got, base)
		}
	})

	// A measurement of THIS model on THIS box outranks a fleet-wide configured
	// guess. Ordering is measured -> seed -> proxy; a stale low seed must not
	// hold a box down once it has measured itself.
	t.Run("measured_rate_outranks_a_low_seed", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, gemmaBuild+"="+fmt.Sprint(starvedSeedTPS), "", "")

		if got := effCapResolved(reg, p, gemmaBuild); got != 2 {
			t.Fatalf("seed-only cap = %d, want 2 (the starved %.0f tok/s seed)", got, starvedSeedTPS)
		}
		observe(reg, 1, measuredGemmaSoloTPS)
		if got := effCapResolved(reg, p, gemmaBuild); got != base {
			t.Fatalf("cap = %d, want %d: the measured rate must outrank the %.0f tok/s seed", got, base, starvedSeedTPS)
		}
	})

	// The first sample is taken as the box drops to one running request, so the
	// alpha=0.3 EWMA still carries batched history and UNDER-states the solo
	// rate. Even a fully contaminated rate(B=2) reading clears the bar, so the
	// measurement path is not resting on a perfectly converged EWMA.
	t.Run("contaminated_first_sample_still_reaches_eight", func(t *testing.T) {
		contended := measuredGemmaSoloTPS / (1 + effectiveTPSLoadFactor*2)
		if contended >= measuredGemmaSoloTPS || contended <= threshold {
			t.Fatalf("rate(B=2) = %.2f tok/s is not a contaminated-but-passing reading against threshold %.2f", contended, threshold)
		}
		reg := newQualityRegistry(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")
		observe(reg, 1, contended)
		if got := effCapResolved(reg, p, gemmaBuild); got != base {
			t.Fatalf("cap = %d at a fully B=2-contaminated reading of %.2f tok/s, want %d", got, contended, base)
		}
	})

	// The point is that the cap sees a TRUE rate, not a permissive one. A box
	// that genuinely measures slow is still capped — the fix raises the cap by
	// improving the INPUT, never by relaxing the bar.
	t.Run("a_genuinely_slow_measurement_is_still_capped", func(t *testing.T) {
		slow := 30.0
		if slow >= threshold {
			t.Fatalf("%.1f tok/s is not below the %.2f tok/s threshold; pick a slower rate", slow, threshold)
		}
		reg := newQualityRegistry(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")
		if got := effCapResolved(reg, p, gemmaBuild); got != base {
			t.Fatalf("before measured evidence cap = %d, want reported %d", got, base)
		}
		observe(reg, 1, slow)
		got := effCapResolved(reg, p, gemmaBuild)
		if want := wantQualityCap(slow, floor, base, defaultQualityCapOvercommit); got != want || got >= base {
			t.Fatalf("cap = %d at a measured %.0f tok/s, want quality cap %d below reported %d", got, slow, want, base)
		}
	})

	// A well-sampled median still outranks a single sample: the relaxation is a
	// FALLBACK below the trusted floors, not a replacement for them.
	t.Run("trusted_median_still_outranks_the_under_sampled_fallback", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		p := prodBox(t, reg)
		enablePerModelQualityCap(t, reg, "", "", "")
		observe(reg, reg.policy.MinSamples(), 30.0)
		observe(reg, 1, measuredGemmaSoloTPS)
		_, n := reg.throughput.SoloMedian(gemmaBuild, quality.ChipClass(p.Hardware))
		if n < reg.policy.MinSamples() {
			t.Fatalf("solo samples = %d, want >= the %d floor", n, reg.policy.MinSamples())
		}
		rate := resolveSolo(reg, p, gemmaBuild)
		if rate.TPS != 30.0 {
			t.Fatalf("resolved rate = %.2f, want the trusted median 30.00 — the single fast sample must not displace it", rate.TPS)
		}
	})
}
