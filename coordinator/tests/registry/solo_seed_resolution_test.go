package registry_test

import (
	"testing"
)

// --- Seed parsing ---

// TestSoloSeedColdStart is the restart scenario: the TPS registry is in-memory
// and wiped by a coordinator restart, so on a fresh registry the seed env must
// carry the per-model cap alone until gated solo samples re-accumulate. The
// gemma seed (14, at or under the 15 floor) pins to 2 at any measured k; the
// gpt-oss cap is k-derived (see the helpers in concurrency_cap_test.go).
func TestSoloSeedColdStart(t *testing.T) {
	reg := newQualityRegistry(testLogger()) // fresh registry == post-restart state
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

// TestSoloSeedFleetFallbackClampedToSlowestNamedClass pins the structural half
// of the fix. Scoping alone still lets an operator write a fast unqualified
// value beside a slow class entry and re-create the bug; the unqualified entry
// is therefore clamped to the slowest class named for that model, so an
// unnamed class can never out-rank the slowest one that WAS named — the same
// min-of-classes invariant SoloMedianAllChips enforces for measured medians.
func TestSoloSeedFleetFallbackClampedToSlowestNamedClass(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	// Operator error: a 70 fleet-wide value alongside a 14 tok/s M1 Pro entry.
	enablePerModelQualityCap(t, reg,
		gemmaBuild+"=70,"+gemmaBuild+"@M1|Pro=14,"+gemmaBuild+"@M4|Max=70", "", "")

	// The named slow class gets its own rate.
	slow := classProvider(t, reg, "m1pro", gemmaBuild, "M1", "Pro")
	if got := resolveSolo(reg, slow, gemmaBuild); got.TPS != 14 {
		t.Fatalf("M1|Pro resolved %v, want its own 14", got.TPS)
	}
	// An UNNAMED class takes the fleet-wide entry clamped down to 14, not 70.
	unnamed := classProvider(t, reg, "m2max", gemmaBuild, "M2", "Max")
	if got := resolveSolo(reg, unnamed, gemmaBuild); got.TPS != 14 {
		t.Fatalf("unnamed M2|Max resolved %v, want the clamped 14 — an unnamed class must never out-rank the slowest named one", got.TPS)
	}
	named := classProvider(t, reg, "m4max", gemmaBuild, "M4", "Max")
	if got := resolveSolo(reg, named, gemmaBuild); got.TPS != 70 {
		t.Fatalf("M4|Max resolved %v, want its own 70 — the clamp must not touch a named class", got.TPS)
	}
}

// TestSoloSeedClassEntryYieldsToMeasuredSamples: a class-qualified seed is a
// COLD-START estimate, not a pin. Once the provider's own class has enough
// gated solo samples the median wins, exactly as an unqualified seed does.
func TestSoloSeedClassEntryYieldsToMeasuredSamples(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14,"+gemmaBuild+"@M4|Max=70", "", "5")
	p := classProvider(t, reg, "m4max", gemmaBuild, "M4", "Max")
	for _, v := range []float64{30, 32, 33, 34, 36} { // median 33
		reg.throughput.RecordSolo(gemmaBuild, "M4|Max", v)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 33 {
		t.Fatalf("resolved %v, want the measured 33 — the class seed must not outrank its own class's samples", got.TPS)
	}
}
