package store

// Prices are micro-USD per million tokens, then multiplied by an integer
// provider share percentage: this denominator preserves both exactly.
const ModelTokenPayoutScale int64 = 100_000_000

type ModelTokenEarning struct {
	ProviderEarning
	FractionalMicroUSD int64
}
