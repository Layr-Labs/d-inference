package registry

// pooled_kv_rates.go — the per-slot KV-rate table inside pooledTokenBudget.
//
// providerPooledTokenBudgetWithLayout used to allocate a map[string]int64 for
// every provider on every routing scan (~11% of the fleet-scale scan's
// allocation volume) to remember each budget slot's KVBytesPerToken. A box
// serves a handful of co-resident models, so the table is a fixed inline
// array that only spills to the heap past pooledKVRateInline entries.
// Semantics match the map exactly: one entry per model, a later slot for the
// same model overwrites the earlier rate (last write wins), and an unknown
// model reads as 0.

// pooledKVRateInline is the inline capacity of the rate table.
const pooledKVRateInline = 4

// slotKVRate pairs a budget slot's model with its clamped KV rate.
type slotKVRate struct {
	model string
	rate  int64
}

// setKVRate records (or overwrites) the rate for model.
func (p *pooledTokenBudget) setKVRate(model string, rate int64) {
	for i := 0; i < p.kvRateCount && i < pooledKVRateInline; i++ {
		if p.kvRates[i].model == model {
			p.kvRates[i].rate = rate
			return
		}
	}
	for i := range p.kvRatesSpill {
		if p.kvRatesSpill[i].model == model {
			p.kvRatesSpill[i].rate = rate
			return
		}
	}
	if p.kvRateCount < pooledKVRateInline {
		p.kvRates[p.kvRateCount] = slotKVRate{model: model, rate: rate}
	} else {
		p.kvRatesSpill = append(p.kvRatesSpill, slotKVRate{model: model, rate: rate})
	}
	p.kvRateCount++
}

// kvRateFor returns the recorded rate for model, or 0 when no budget slot
// reported one (the same "map miss ⇒ 0" every consumer relied on).
func (p *pooledTokenBudget) kvRateFor(model string) int64 {
	for i := 0; i < p.kvRateCount && i < pooledKVRateInline; i++ {
		if p.kvRates[i].model == model {
			return p.kvRates[i].rate
		}
	}
	for i := range p.kvRatesSpill {
		if p.kvRatesSpill[i].model == model {
			return p.kvRatesSpill[i].rate
		}
	}
	return 0
}
