package registry

import (
	"math"
)

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

// resolvedModelTPSLocked returns the best per-model decode/prefill TPS samples
// for a provider. BackendCapacity.Slots is authoritative for Swift providers:
// when the matching slot reports observed EWMAs, prefer them over static
// registration benchmarks. Non-positive observed values are treated as missing.
// Caller must hold p.mu.
func resolvedModelTPSLocked(p *Provider, model string) (decodeTPS, prefillTPS float64) {
	decodeTPS = resolvedDecodeTPS(p)
	prefillTPS = resolvedPrefillTPS(p)
	if p.BackendCapacity == nil {
		return decodeTPS, prefillTPS
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model != model {
			continue
		}
		if slot.ObservedDecodeTPS > 0 {
			decodeTPS = slot.ObservedDecodeTPS
		}
		if slot.ObservedPrefillTPS > 0 {
			prefillTPS = slot.ObservedPrefillTPS
		}
		break
	}
	return decodeTPS, prefillTPS
}

func resolvedPrefillTPS(p *Provider) float64 {
	if p.PrefillTPS > 0 {
		return p.PrefillTPS
	}
	return resolvedDecodeTPS(p) * routingPolicy.PrefillToDecodeRatio()
}
