package kvbudget

// Pending accumulates coordinator-pending work against one reconstructed pool.
// Byte charges use the same resident or conservative cold-model rate as admission.
type Pending struct {
	Tokens     int
	Bytes      int64
	BytesKnown bool
}

func NewPending(pool *Budget) Pending {
	return Pending{BytesKnown: pool.ByteMode}
}

func (p *Pending) Add(pool *Budget, model string, tokens int) {
	p.Tokens += tokens
	if p.BytesKnown {
		rate := ResolveRate(pool, pool.RateFor(model))
		p.Bytes = AddByteCharge(p.Bytes, int64(tokens), rate)
	}
}
