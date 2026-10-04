package store

// ModelPrice represents a custom per-model price override for an account.
// All prices are micro-USD per 1M tokens. CacheReadPrice is the rate for
// prompt tokens served from a provider's prefix cache; nil means the row sets
// none and billing derives it from InputPrice (payments.RatesFor).
type ModelPrice struct {
	AccountID      string `json:"account_id"`
	Model          string `json:"model"`
	InputPrice     int64  `json:"input_price"`
	OutputPrice    int64  `json:"output_price"`
	CacheReadPrice *int64 `json:"cache_read_price,omitempty"`
}

// clone returns a copy sharing no memory with p, so a stored or cached row and
// its callers never alias CacheReadPrice.
func (p ModelPrice) Clone() ModelPrice {
	if p.CacheReadPrice != nil {
		v := *p.CacheReadPrice
		p.CacheReadPrice = &v
	}
	return p
}
