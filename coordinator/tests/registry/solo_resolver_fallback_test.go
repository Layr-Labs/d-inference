package registry_test

import (
	"testing"
)

// --- Resolver fallback chain ---

func TestResolvedSoloModelTPSFallbackChain(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14", "", "")
	p := mixedBoxProvider(t, reg, "mixed", 93) // ChipFamily "M3"

	// (c) seed only — no solo samples anywhere.
	if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 14 || !got.PerModel {
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
		reg.throughput.RecordSolo(gemmaBuild, chip, v)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 14 || !got.PerModel {
		t.Fatalf("cross-chip fallback = %+v, want seed-bounded tps 14 (pooled median 16), perModel true", got)
	}

	// (a) per-(model, chip) median wins over cross-chip and seed once trusted.
	for _, v := range []float64{10, 12, 12, 12, 30} {
		reg.throughput.RecordSolo(gemmaBuild, "M3|Max", v)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 12 || !got.PerModel {
		t.Fatalf("per-chip solo median = %+v, want tps 12, perModel true", got)
	}

	// (d) a model with no solo data and no seed falls back to the provider-level
	// rate (the registration benchmark).
	if got := resolveSolo(reg, p, gptossBuild); got.TPS != 93 || got.PerModel {
		t.Fatalf("provider-level fallback = %+v, want tps 93, perModel false", got)
	}
}

// TestSoloResolverChipClassKeying is the correctness-critical safety test for
// Fix 2: solo caps are keyed by chip CLASS (family+tier), and the cross-class
// fallback is the MIN of per-class medians. Together these guarantee the
// resolver never hands a slow box a rate faster than its own class demonstrated
// — the over-admission that collapses a slow box under load.
func TestSoloResolverChipClassKeying(t *testing.T) {
	// (a) same-class primary lookup applies: an M3|Max box uses M3|Max samples.
	t.Run("same_class_primary", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := mixedBoxProvider(t, reg, "m3max", 93)
		setChipClass(p, "M3", "Max")
		for _, v := range []float64{10, 12, 12, 12, 30} { // median 12
			reg.throughput.RecordSolo(gemmaBuild, "M3|Max", v)
		}
		if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 12 || !got.PerModel {
			t.Fatalf("same-class resolver = %+v, want tps 12, perModel true", got)
		}
	})

	// (b) cross-tier isolation: an M4|Pro box must NOT inherit the fast M4|Max
	// tier's rate. With family-only keying both tiers pooled under "M4" and the
	// Pro box got the Max rate; class keying keeps them separate, so the Pro box
	// resolves to its OWN slower median.
	t.Run("cross_tier_isolation", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := mixedBoxProvider(t, reg, "m4pro", 93)
		setChipClass(p, "M4", "Pro")
		for i := 0; i < 5; i++ {
			reg.throughput.RecordSolo(gemmaBuild, "M4|Max", 40) // fast tier
		}
		for _, v := range []float64{14, 15, 15, 15, 16} { // slow tier, median 15
			reg.throughput.RecordSolo(gemmaBuild, "M4|Pro", v)
		}
		if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 15 {
			t.Fatalf("M4|Pro resolved %v, want 15 (its own class median), NOT the M4|Max 40", got.TPS)
		}
	})

	// (c) conservative cross-class fallback: a box whose own class has no samples
	// falls to SoloMedianAllChips, which returns the MIN of class medians — the
	// slow class (10), never the fast one (40). A slow box can never be over-capped.
	t.Run("conservative_cross_class_fallback", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := mixedBoxProvider(t, reg, "m2max", 93)
		setChipClass(p, "M2", "Max") // no M2|Max samples exist
		for i := 0; i < 5; i++ {
			reg.throughput.RecordSolo(gemmaBuild, "M4|Max", 40) // fast class
		}
		for i := 0; i < 5; i++ {
			reg.throughput.RecordSolo(gemmaBuild, "M1", 10) // slow class
		}
		if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 10 || !got.PerModel {
			t.Fatalf("cross-class fallback = %+v, want tps 10 (min of class medians), NOT the fast 40", got)
		}
	})

	// (d) cold-start safety: a cold-class box with only FASTER classes present
	// still gets the conservative min of those class medians (25, the slower of
	// the two), never the fastest (40).
	t.Run("cold_class_conservative_min", func(t *testing.T) {
		reg := newQualityRegistry(testLogger())
		enablePerModelQualityCap(t, reg, "", "", "")
		p := mixedBoxProvider(t, reg, "m2ultra", 93)
		setChipClass(p, "M2", "Ultra") // no M2|Ultra samples exist
		for i := 0; i < 5; i++ {
			reg.throughput.RecordSolo(gemmaBuild, "M4|Max", 40) // fastest
		}
		for i := 0; i < 5; i++ {
			reg.throughput.RecordSolo(gemmaBuild, "M3|Max", 25) // slower of the two
		}
		if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 25 {
			t.Fatalf("cold-class resolver = %v, want 25 (conservative min), never the fastest 40", got.TPS)
		}
	})
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
	reg := newQualityRegistry(testLogger())
	// Floor raised to 6: five samples are NOT yet the trusted tier.
	enablePerModelQualityCap(t, reg, "", "", "6")
	p := mixedBoxProvider(t, reg, "mixed", 93)

	// No measurement at all — the terminal provider-level fallback. This is
	// the only remaining route to resolvedDecodeTPS(p), so it is pinned here.
	if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 93 || got.PerModel {
		t.Fatalf("no samples = %+v, want the provider-level fallback (93, perModel false)", got)
	}

	for range 5 {
		reg.throughput.RecordSolo(gemmaBuild, "M3|Max", 14)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 14 || !got.PerModel {
		t.Fatalf("below min samples = %+v, want the under-sampled measured rate (14, perModel true), not the provider-level 93", got)
	}
	reg.throughput.RecordSolo(gemmaBuild, "M3|Max", 14)
	if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 14 || !got.PerModel {
		t.Fatalf("at min samples = %+v, want (14, perModel true)", got)
	}
}

func TestResolvedSoloModelTPSKillSwitch(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	// Kill switch OFF: solo medians and seed present but must be ignored —
	// resolvedDecodeTPS(p) exactly, at every consumer.
	enablePerModelQualityCap(t, reg, gemmaBuild+"=14", "false", "")
	p := mixedBoxProvider(t, reg, "mixed", 93)
	for i := 0; i < 10; i++ {
		reg.throughput.RecordSolo(gemmaBuild, "M3|Max", 14)
	}
	if got := resolveSolo(reg, p, gemmaBuild); got.TPS != 93 || got.PerModel {
		t.Fatalf("kill switch off: resolver = %+v, want provider-level (93, perModel false)", got)
	}
}
