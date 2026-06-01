package registry

import (
	"math"
)

// resolveEffectiveTPS returns the best available decode TPS estimate.
// Fallback chain: observed EWMA → fleet median → load-scaled benchmark.
func resolveEffectiveTPS(snap routingSnapshot) float64 {
	if snap.observedDecodeTPS > 0 {
		return snap.observedDecodeTPS
	}
	if snap.fleetMedianTPS > 0 {
		return snap.fleetMedianTPS
	}
	return effectiveDecodeTPS(snap.decodeTPS, snap.backendRunning)
}

// effectiveDecodeTPS scales the static decode TPS down by current
// backend batch size. Returns the static value when the load factor is
// disabled or batch is unknown. Floored at 1 token/s to avoid divide-
// by-zero.
//
// Note on the floor + large reqMax: when effectiveTPS bottoms out, the
// per-request decode cost (reqMax / effectiveTPS * 1000) can become
// very large for big reqMax values. This is intentional — a saturated
// provider should look strictly worse than less-saturated peers — and
// the maxConcurrency gate in snapshotProviderLocked already prevents
// us from getting here when batchSize exceeds the per-tier cap.
func effectiveDecodeTPS(staticTPS float64, backendRunning int) float64 {
	if staticTPS <= 0 {
		return 1.0
	}
	if effectiveTPSLoadFactor <= 0 || backendRunning <= 0 {
		return staticTPS
	}
	tps := staticTPS / (1.0 + effectiveTPSLoadFactor*float64(backendRunning))
	if tps < 1.0 {
		tps = 1.0
	}
	return tps
}

func resolvedDecodeTPS(p *Provider) float64 {
	if p.DecodeTPS > 0 {
		return p.DecodeTPS
	}
	bw := float64(p.Hardware.MemoryBandwidthGBs)
	if bw > 0 {
		return math.Sqrt(bw)
	}
	return 1.0
}

func resolvedPrefillTPS(p *Provider) float64 {
	if p.PrefillTPS > 0 {
		return p.PrefillTPS
	}
	return resolvedDecodeTPS(p) * 4.0
}

func providerModelIDs(p *Provider) []string {
	if p == nil {
		return nil
	}
	ids := make([]string, 0, len(p.Models))
	for _, m := range p.Models {
		ids = append(ids, m.ID)
	}
	return ids
}
