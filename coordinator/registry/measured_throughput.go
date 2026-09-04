package registry

// MeasuredThroughput is the decode/prefill tok/s a machine has actually been
// measured at — the number a dashboard shows next to "Decode". It is distinct
// from the scheduler's routing estimate (resolvedModelTPSLocked), which falls
// back to a sqrt(memory-bandwidth) heuristic so every provider has a rankable
// cost; a display must never print that placeholder as a measurement.
//
// Zero means "not measured yet" (a freshly connected box that has not served
// a request), and callers render it as an explicit blank.
type MeasuredThroughput struct {
	DecodeTPS  float64
	PrefillTPS float64
}

// MeasuredThroughputLocked resolves the machine's measured throughput from the
// live heartbeat state. Caller must hold p.mu.
//
// Precedence, per axis (decode and prefill resolve independently):
//
//  1. The heartbeat EWMA of the slot serving CurrentModel — the model the
//     machine is decoding right now.
//  2. The largest EWMA across the other loaded slots — the box has been
//     measured, just not yet on the active model (e.g. it was just swapped in).
//  3. The registration-time benchmark (PrefillTPS / DecodeTPS). Current Swift
//     providers never send it; legacy providers did.
//  4. Zero: unmeasured.
func (p *Provider) MeasuredThroughputLocked() MeasuredThroughput {
	out := MeasuredThroughput{}
	if p.BackendCapacity != nil {
		var bestDecode, bestPrefill float64
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == p.CurrentModel {
				if slot.ObservedDecodeTPS > 0 {
					out.DecodeTPS = slot.ObservedDecodeTPS
				}
				if slot.ObservedPrefillTPS > 0 {
					out.PrefillTPS = slot.ObservedPrefillTPS
				}
				continue
			}
			if slot.ObservedDecodeTPS > bestDecode {
				bestDecode = slot.ObservedDecodeTPS
			}
			if slot.ObservedPrefillTPS > bestPrefill {
				bestPrefill = slot.ObservedPrefillTPS
			}
		}
		if out.DecodeTPS <= 0 {
			out.DecodeTPS = bestDecode
		}
		if out.PrefillTPS <= 0 {
			out.PrefillTPS = bestPrefill
		}
	}
	if out.DecodeTPS <= 0 && p.DecodeTPS > 0 {
		out.DecodeTPS = p.DecodeTPS
	}
	if out.PrefillTPS <= 0 && p.PrefillTPS > 0 {
		out.PrefillTPS = p.PrefillTPS
	}
	return out
}
