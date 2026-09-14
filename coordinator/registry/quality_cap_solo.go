package registry

// soloTransferDestBoundLocked is the upper bound the DESTINATION provider's own
// hardware places on a cross-class solo transfer, for use when that provider's
// chip class contributed no sample of its own.
//
// It is resolvedDecodeTPS(p) — the registration benchmark, else the
// sqrt(memory_bandwidth) proxy — with one exclusion: resolvedDecodeTPS returns
// a hard-coded 1.0 for a provider that reports neither, and clamping to that
// sentinel would pin an otherwise-fine box to cap 1 purely because it went
// quiet. A provider is never capped at 1 by its own silence (see the
// before-first-completion note on resolvedSoloModelTPSLocked), so absent both
// signals this reports no bound and the transfer keeps whatever the seed and
// class-count arms gave it.
//
// The rate is model-AGNOSTIC, which is exactly why it may only ever lower a
// transferred value and never raise one: it under-states fast models (a ~57
// tok/s gpt-oss reads ~28 through the bandwidth proxy), so using it as a
// ceiling is conservative while using it as a floor would not be. Caller holds
// p.mu.
func soloTransferDestBoundLocked(p *Provider) (float64, bool) {
	if p.DecodeTPS <= 0 && p.Hardware.MemoryBandwidthGBs <= 0 {
		return 0, false
	}
	return resolvedDecodeTPS(p), true
}

// soloModelTPS is a static single-stream decode rate for a (provider, model)
// pair plus its provenance. perModel is true when the rate came from a
// model-specific source — a gated solo median or the seed env — which is
// trustworthy for capping even when the provider never reported a registration
// benchmark; false means the rate is the provider-level resolvedDecodeTPS
// chain (registration benchmark, or the model-agnostic sqrt-bandwidth proxy
// that only dedicated models may be capped from).
type soloModelTPS struct {
	tps      float64
	perModel bool
}

// resolvedSoloModelTPSLocked resolves the static solo decode rate the quality
// cap should use for (p, model). Fallback chain, most- to least-specific:
//
//  1. per-(model, chip CLASS) solo median — gated samples only (solo_tps.go),
//     keyed by chipClassKey (family+tier) so a fast tier never lends its rate
//     to a slow one — once it has ≥ qualityCapSoloMinSamples samples;
//  2. the MIN of the per-class solo medians across chip classes (conservative
//     cross-class transfer, SoloMedianAllChips), same total-sample floor, and
//     only when that minimum is actually BOUNDED for this provider — see
//     "when cross-class transfer is admissible" below;
//  3. the same-class solo median with FEWER than qualityCapSoloMinSamples
//     samples (but at least one), then the bounded cross-class median under
//     the same relaxation. These are under-sampled but they are still
//     MEASURED and still solo-gated, and the alternative below them is a
//     model-AGNOSTIC hardware proxy: preferring sqrt(memory_bandwidth) over
//     the provider's own measurement of this exact model is strictly worse
//     information. See the note on convergence below;
//  4. the modelSoloTPSSeedEnv seed for this provider's chip class when there
//     is no measured rate at all — the class-qualified entry, else the
//     fleet-wide entry clamped to the slowest class the operator named
//     (soloTPSSeedForClass). The TPS registry is in-memory and restart-wiped,
//     and a provider that has completed no request reports no rate (see
//     below);
//  5. the provider-level resolvedDecodeTPS(p) — exactly the pre-per-model
//     behavior, including its sqrt-bandwidth fallback semantics.
//
// When cross-class transfer is admissible. Steps (2) and (3) hand a provider a
// rate its own chip class did not produce, so the transferred value needs an
// upper bound or a fast class silently sets a slow class's cap — the exact
// over-admission this whole cap exists to prevent. Three things can supply
// that bound, and at least one MUST hold:
//
//   - a modelSoloTPSSeedEnv seed applies to THIS provider's chip class
//     (soloTPSSeedForClass) — the configured cold-start estimate clamps the
//     transfer from above;
//   - the provider's own class contributed at least one sample, so the min of
//     per-class medians cannot exceed what its own class demonstrated;
//   - at least two classes contributed. This one is WEAKER than it looks and
//     is not a bound on the destination: the min over {M4 Max, M3 Max} is
//     still a Max-tier rate, and handing it to an unsampled M1 Pro over-states
//     that box by 4x. It is admitted anyway because it is a partial brake —
//     refusing it drops to (4)/(5), and resolvedDecodeTPS is usually FASTER
//     than the cross-class min (a mixed box benchmarked on gpt-oss reads 93
//     tok/s), so refusing would LOOSEN the cap in most fleet shapes rather
//     than tighten it. Measured: over 600 shapes where this arm is the sole
//     admission reason, refusing loosens 338, tightens 81, no change in 181.
//     soloTransferDestBoundLocked below supplies the bound this arm lacks.
//
// With none of them, the "min of per-class medians" is a single fast class's
// rate being applied to an unsampled slower one — one M4 Max sample setting an
// unseeded M1 Pro's rate. That is refused: the resolver drops to (4)/(5),
// which is the pre-per-model behaviour and errs toward serving rather than
// toward capping a box from evidence about different hardware.
//
// Reachability note for whoever edits crossClassBounded next: the third arm
// cannot fire on the current production fleet. The shipped
// EIGENINFERENCE_MODEL_SOLO_TPS_SEED carries UNQUALIFIED entries for both
// served models ("gemma-4-26b-qat-4bit=14,gpt-oss-20b=30"), and an unqualified
// entry resolves through modelSoloTPSSeedFleet for EVERY chip class, so
// hasSeed is true fleet-wide and the first arm always short-circuits it. The
// arm is live only for a model added without an unqualified seed entry.
// TestSoloSeedUnqualifiedEntryMakesEveryClassSeeded pins that.
//
// What a provider reports BEFORE its first completion: nothing. The bridge's
// EWMA (EngineV2Bridge.observedDecodeTpsEwma) is 0 until updateDecodeTpsEwma
// runs on a terminal event, `observed_decode_tps` is `omitempty`, and the
// heartbeat ingest only calls RecordSolo when the reported value is > 0
// (heartbeat.go). So a fresh provider contributes NO solo sample, reaches (4)
// or (5), and is never capped at 1 by its own silence. Steps (3) can only
// engage once a real decode has been measured.
//
// Under-sampled samples converge from BELOW, which is the safe direction. The
// bridge EWMA (alpha = 0.3) blends prior batched decodes, so the first sample
// taken as the box drops to a single running request UNDER-states the true
// solo rate; it can never materially over-state it (solo is the fastest case,
// and the ingest path already clamps to maxDecodeTPS). An under-stated rate
// yields a TIGHTER cap, never a permissive one.
//
// The rate is deliberately STATIC (never an under-load EWMA): an observed rate
// collapses under the very overload the cap exists to prevent, which would
// drive the cap to 1 in a feedback loop. Solo medians preserve that property
// because ingest is gated on a fully uncontended box.
//
// The qualityCapPerModelTPSEnv kill switch (false) short-circuits to (4),
// restoring resolvedDecodeTPS(p) at every wired site exactly. Caller holds
// r.mu and p.mu.
func (r *Registry) resolvedSoloModelTPSLocked(p *Provider, model string) soloModelTPS {
	if qualityCapPerModelTPS {
		chipClass := chipClassKey(p.Hardware)
		classTPS, classN := r.tpsRegistry.SoloMedian(model, chipClass)
		if classN >= qualityCapSoloMinSamples && classTPS > 0 {
			return soloModelTPS{tps: classTPS, perModel: true}
		}
		seed, hasSeed := soloTPSSeedForClass(model, chipClass)
		allTPS, allN, allClasses := r.tpsRegistry.SoloMedianAllChips(model)
		// Seed-clamp the cross-class transfer: observations from faster classes
		// cannot widen an unsampled slower class's cap above its configured
		// cold-start estimate. Applies at both sample floors.
		if allTPS > 0 && hasSeed && seed < allTPS {
			allTPS = seed
		}
		// Destination-clamp it too, when this provider's own class contributed
		// nothing. The seed clamp above only fires for a seeded class, and
		// allClasses > 1 bounds the transfer against the sampled POPULATION,
		// not against the box receiving it. This box's own hardware evidence
		// does bound it: a rate it cannot sustain on any model is not one it
		// sustains on this one. Model-agnostic, so it can only ever LOWER a
		// transferred rate — never widen one, and never applied when the class
		// has its own samples (those are strictly better evidence).
		if allTPS > 0 && classN == 0 {
			if own, ok := soloTransferDestBoundLocked(p); ok && own < allTPS {
				allTPS = own
			}
		}
		// ...and refuse it outright when nothing bounds it (see above). An
		// unbounded transfer is not conservative just because the function it
		// came from is named for a minimum.
		crossClassBounded := hasSeed || classN > 0 || allClasses > 1
		if crossClassBounded && allN >= qualityCapSoloMinSamples && allTPS > 0 {
			return soloModelTPS{tps: allTPS, perModel: true}
		}
		// Measured but under-sampled. Ranked below both trusted medians and
		// above the seed: a real solo-gated measurement of THIS model beats a
		// fleet-wide configured guess, and both beat the model-agnostic
		// sqrt-bandwidth proxy that pins a fast model to cap 1-2.
		if classN > 0 && classTPS > 0 {
			return soloModelTPS{tps: classTPS, perModel: true}
		}
		if crossClassBounded && allN > 0 && allTPS > 0 {
			return soloModelTPS{tps: allTPS, perModel: true}
		}
		if hasSeed {
			return soloModelTPS{tps: seed, perModel: true}
		}
	}
	return soloModelTPS{tps: resolvedDecodeTPS(p), perModel: false}
}
