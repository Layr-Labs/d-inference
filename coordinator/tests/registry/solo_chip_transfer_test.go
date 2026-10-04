package registry_test

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// TestSoloResolverConvergesAcrossManyBoxes is a small sanity spread: several
// mixed boxes with different provider-level benchmarks all resolve the SAME
// per-model rate once the solo median is trusted — the property that makes
// caps chip-honest instead of benchmark-inherited.
func TestSoloResolverConvergesAcrossManyBoxes(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enablePerModelQualityCap(t, reg, "", "", "")
	for i := 0; i < 5; i++ {
		reg.throughput.RecordSolo(gemmaBuild, "M3|Max", 14)
	}
	for i, bench := range []float64{58, 73, 93} {
		p := mixedBoxProvider(t, reg, fmt.Sprintf("box-%d", i), bench)
		if got := effCapResolved(reg, p, gemmaBuild); got != 2 {
			t.Fatalf("box benchmarked %v tok/s: gemma cap = %d, want 2 regardless of the provider-level benchmark", bench, got)
		}
	}
}

// TestSoloSeedAbsentRefusesUnboundedCrossClassTransfer is the second half of
// the seed blocker. TestSoloSeedIsChipClassScoped covers the SEEDED path; this
// one covers what the fleet actually looked like while
// EIGENINFERENCE_MODEL_SOLO_TPS_SEED reached no coordinator at all (it lived
// only in deploy/environments/prod.env, which nothing consumes, and was absent
// from deploy/gcp/prod/release-env-defaults).
//
// With no seed installed, hasSeed is false for every model, so the seed clamp
// on the cross-class transfer never fires. SoloMedianAllChips is described as
// the MIN of per-class medians, but with a single sampled class that "minimum"
// is that one class's own rate — so ONE M4 Max sample became the per-model
// rate of an unsampled M1 Pro, the precise over-admission the class keying
// exists to prevent, arriving through the path meant to prevent it.
//
// The resolver must now refuse a cross-class transfer that nothing bounds and
// drop to the provider-level chain instead. It must NOT refuse the bounded
// transfers — that would make a real fix out of a blunt one.
func TestSoloSeedAbsentRefusesUnboundedCrossClassTransfer(t *testing.T) {
	// gemma-4 is dedicated in production, so the fall-through is the
	// sqrt(memory_bandwidth) proxy and the cap difference is observable.
	const fastTPS = 70.0
	newFleet := func(seed string) (*qualityFixture,

		*production.Provider,

	) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, seed, "", "")
		reg.SetDedicatedModels([]string{"gemma-4"})
		return reg, classProvider(t, reg, "m1pro", gemmaBuild, "M1", "Pro")
	}
	// The cap one unbounded M4 Max sample would have granted the M1 Pro.
	unboundedCap := wantQualityCap(fastTPS, 15, 8, defaultQualityCapOvercommit)

	// (a) The reviewer's case: one fast-class sample, no seed, and a provider
	// on a slower class that has never been sampled.
	t.Run("one_fast_sample_no_seed", func(t *testing.T) {
		reg, p := newFleet("")
		reg.throughput.RecordSolo(gemmaBuild, "M4|Max", fastTPS)

		got := resolveSolo(reg, p, gemmaBuild)
		if got.TPS == fastTPS || got.PerModel {
			t.Fatalf("unseeded M1|Pro resolved %+v — it inherited the single M4 Max sample as a per-model rate", got)
		}
		wantFallback := providerDecodeFallback(p)
		if got.TPS != wantFallback {
			t.Fatalf("unseeded M1|Pro resolved %v, want the provider-level fallback %v", got.TPS, wantFallback)
		}
		if cap := effCapResolved(reg, p, gemmaBuild); cap >= unboundedCap {
			t.Fatalf("unseeded M1|Pro cap = %d, want < %d (the cap the unbounded %v tok/s transfer granted)",
				cap, unboundedCap, fastTPS)
		}
	})

	// (b) The same hole at the TRUSTED sample floor: five samples are still
	// five samples of the WRONG class. Sample count is not a class bound.
	t.Run("trusted_floor_single_class_no_seed", func(t *testing.T) {
		reg, p := newFleet("")
		for range reg.policy.MinSamples() {
			reg.throughput.RecordSolo(gemmaBuild, "M4|Max", fastTPS)
		}
		if got := resolveSolo(reg, p, gemmaBuild); got.TPS == fastTPS || got.PerModel {
			t.Fatalf("unseeded M1|Pro resolved %+v at the trusted floor — %d samples of one foreign class still bound nothing",
				got, reg.policy.MinSamples())
		}
	})

	// (c) Installing the seed is what makes the transfer admissible again, and
	// it lands on the conservative class-scoped floor rather than the fast
	// sample. This is the shipped release-env-defaults value.
	t.Run("prod_seed_bounds_the_same_fleet", func(t *testing.T) {
		reg, p := newFleet(prodSoloTPSSeed(t))
		reg.throughput.RecordSolo(gemmaBuild, "M4|Max", fastTPS)

		got := resolveSolo(reg, p, gemmaBuild)
		if got.TPS != 14 || !got.PerModel {
			t.Fatalf("seeded M1|Pro resolved %+v, want the clamped seed 14 as a per-model rate", got)
		}
		if cap := effCapResolved(reg, p, gemmaBuild); cap != 2 {
			t.Fatalf("seeded M1|Pro cap = %d, want 2 (seed 14 ≤ floor 15 → quality batch 1 × overcommit)", cap)
		}
	})

	// (d) Two contributing classes make the minimum a REAL cross-class
	// minimum, so the transfer stays admissible with no seed at all. Without
	// this the fix would be a blanket disable of steps (2)/(3).
	t.Run("two_classes_still_transfer_unseeded", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := classProvider(t, reg, "m2pro", gemmaBuild, "M2", "Pro")
		reg.throughput.RecordSolo(gemmaBuild, "M4|Max", fastTPS)
		reg.throughput.RecordSolo(gemmaBuild, "M1|Max", 12)

		if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 12 || !got.PerModel {
			t.Fatalf("unseeded M2|Pro resolved %+v, want 12 (min across two sampled classes), never the fast %v", got, fastTPS)
		}
	})

	// (e) A provider whose OWN class contributed is bounded by its own
	// evidence: the min can never exceed what its class demonstrated, seed or
	// no seed.
	t.Run("own_class_sample_bounds_transfer_unseeded", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := classProvider(t, reg, "m1pro-sampled", gemmaBuild, "M1", "Pro")
		for range reg.policy.MinSamples() {
			reg.throughput.RecordSolo(gemmaBuild, "M4|Max", fastTPS)
		}
		reg.throughput.RecordSolo(gemmaBuild, "M1|Pro", 13)

		if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 13 || !got.PerModel {
			t.Fatalf("unseeded M1|Pro with one own-class sample resolved %+v, want 13 (its own class), never the fast %v", got, fastTPS)
		}
	})
}

// TestSoloCrossClassTransferClampedToDestinationHardware covers the hole that
// `allClasses > 1` leaves open. That arm asks whether the sampled POPULATION
// contains more than one class; it never asks whether the box RECEIVING the
// transfer can sustain the result. With M4 Max and M3 Max both sampled, the
// min is still a Max-tier rate, and an unsampled M1 Pro inherits it.
//
// Removing the arm does not fix that. Measured over 600 fleet shapes where the
// arm is the sole admission reason, refusing the transfer LOOSENS the cap in
// 338 and tightens it in only 81, because the refusal path is
// resolvedDecodeTPS(p) — a mixed box benchmarked on gpt-oss reads 93 tok/s,
// far above any gemma cross-class min. The bound has to come from the
// destination box, not from deleting the population check: clamping to
// resolvedDecodeTPS is tighter than the status quo in 129 of those shapes and
// looser in none.
func TestSoloCrossClassTransferClampedToDestinationHardware(t *testing.T) {
	const (
		m4Max = 70.0
		m3Max = 65.0
	)
	twoFastClasses := func(reg *qualityFixture,

	) {
		for range reg.policy.MinSamples() {
			reg.throughput.RecordSolo(gemmaBuild, "M4|Max", m4Max)
			reg.throughput.RecordSolo(gemmaBuild, "M3|Max", m3Max)
		}
	}

	// (a) The reported case. Two sampled classes satisfy `allClasses > 1`, so
	// the transfer is admitted — but it is clamped to the 18 tok/s this M1 Pro
	// actually benchmarked, not the 65 that is merely the slower of two
	// machines it is not.
	t.Run("min_of_two_fast_classes_clamped_to_own_rate", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		reg.SetDedicatedModels([]string{"gemma-4"})
		p := benchClassProvider(t, reg, "m1pro", gemmaBuild, "M1", "Pro", 18)
		twoFastClasses(reg)

		got := resolveSolo(reg, p, gemmaBuild)
		if got.TPS != 18 || !got.PerModel {
			t.Fatalf("unsampled M1|Pro resolved %+v, want the 18 tok/s it benchmarked — %v is the min of two Max-tier classes, which bounds the sampled population, not this box",
				got, m3Max)
		}
		// The clamp must actually move admission, not just the number.
		clampedCap := effCapResolved(reg, p, gemmaBuild)
		unclampedCap := explicitRateCap(reg, p, gemmaBuild, quality.Rate{TPS: m3Max, PerModel: true})
		if clampedCap >= unclampedCap {
			t.Fatalf("clamped cap = %d, unclamped cap = %d — the clamp must tighten admission, not merely relabel the rate",
				clampedCap, unclampedCap)
		}
	})

	// (b) The clamp is a CEILING on a transfer, never a floor and never a
	// widening. A box that benchmarked faster than the cross-class min keeps
	// the min: its own rate is model-agnostic and over-states a slow model.
	t.Run("faster_destination_keeps_the_cross_class_min", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := benchClassProvider(t, reg, "m2max", gemmaBuild, "M2", "Max", 93)
		twoFastClasses(reg)

		if got := resolveSolo(reg, p, gemmaBuild); got.TPS != m3Max || !got.PerModel {
			t.Fatalf("destination benchmarked 93 resolved %+v, want the cross-class min %v — the clamp may only lower a transfer", got, m3Max)
		}
	})

	// (c) The clamp is gated on the destination class having contributed
	// NOTHING. A solo sample from this box's own class is strictly better
	// evidence about this model than a model-agnostic hardware proxy, so it
	// must not be pulled down to that proxy.
	t.Run("own_class_sample_outranks_the_hardware_proxy", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := benchClassProvider(t, reg, "m1pro-sampled", gemmaBuild, "M1", "Pro", 18)
		twoFastClasses(reg)
		reg.throughput.RecordSolo(gemmaBuild, "M1|Pro", 30)

		if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 30 || !got.PerModel {
			t.Fatalf("M1|Pro with its own 30 tok/s sample resolved %+v, want 30 — a measured own-class rate outranks the 18 tok/s model-agnostic benchmark", got)
		}
	})

	// (d) resolvedDecodeTPS returns a hard-coded 1.0 for a provider reporting
	// neither a benchmark nor a bandwidth. Clamping to that sentinel would pin
	// the box to cap 1 for being quiet, which the resolver documents it must
	// never do. Absent both signals there is no destination bound at all.
	t.Run("silent_provider_is_not_clamped_to_the_sentinel", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := classProvider(t, reg, "silent", gemmaBuild, "M1", "Pro")
		p.Mu().Lock()
		p.DecodeTPS = 0
		p.Hardware.MemoryBandwidthGBs = 0
		p.Mu().Unlock()
		twoFastClasses(reg)

		got := resolveSolo(reg, p, gemmaBuild)
		if got.TPS != m3Max {
			t.Fatalf("silent provider resolved %+v, want the unclamped %v — a 1.0 sentinel is not evidence and must not become a bound", got, m3Max)
		}
		if cap := effCapResolved(reg, p, gemmaBuild); cap <= 1 {
			t.Fatalf("silent provider cap = %d, want > 1 — a provider must never be capped at 1 by its own silence", cap)
		}
	})
}
