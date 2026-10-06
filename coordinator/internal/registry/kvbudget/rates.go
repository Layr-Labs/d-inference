package kvbudget

// Per-slot KV-rate storage for the reconstructed Budget.
//
// providerPooledTokenBudget used to allocate a map[string]int64 for
// every provider on every routing scan (~11% of the fleet-scale scan's
// allocation volume) to remember each budget slot's KVBytesPerToken. A box
// serves a handful of co-resident models, so the table is a fixed inline
// array that only spills to the heap past pooledKVRateInline entries.
// Semantics match the map exactly: one entry per model, a later slot for the
// same model overwrites the earlier rate (last write wins), and an unknown
// model reads as 0.

// InlineRates is the inline capacity of the rate table.
const InlineRates = 4

// RateTable is a small model-to-rate table. A normal provider's resident set
// fits inline; larger sets spill without changing last-write-wins semantics.
type RateTable struct {
	inline [InlineRates]slotKVRate
	count  int
	spill  []slotKVRate
}

// Len returns the number of distinct models with recorded rates.
func (p *RateTable) Len() int { return p.count }

// slotKVRate pairs a budget slot's model with its clamped KV rate.
type slotKVRate struct {
	model string
	rate  int64
}

// Set records (or overwrites) the rate for model.
func (p *RateTable) Set(model string, rate int64) {
	for i := 0; i < p.Len() && i < InlineRates; i++ {
		if p.inline[i].model == model {
			p.inline[i].rate = rate
			return
		}
	}
	for i := range p.spill {
		if p.spill[i].model == model {
			p.spill[i].rate = rate
			return
		}
	}
	if p.Len() < InlineRates {
		p.inline[p.count] = slotKVRate{model: model, rate: rate}
	} else {
		p.spill = append(p.spill, slotKVRate{model: model, rate: rate})
	}
	p.count++
}

// Get returns the recorded rate for model, or 0 when no budget slot
// reported one (the same "map miss ⇒ 0" every consumer relied on).
func (p *RateTable) Get(model string) int64 {
	for i := 0; i < p.Len() && i < InlineRates; i++ {
		if p.inline[i].model == model {
			return p.inline[i].rate
		}
	}
	for i := range p.spill {
		if p.spill[i].model == model {
			return p.spill[i].rate
		}
	}
	return 0
}

// RateFor returns the clamped reported rate for model, or zero if absent.
func (p *Budget) RateFor(model string) int64 { return p.rates.Get(model) }
