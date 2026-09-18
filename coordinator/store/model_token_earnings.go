package store

import "fmt"

// Prices are micro-USD per million tokens, then multiplied by an integer
// provider share percentage: this denominator preserves both exactly.
const ModelTokenPayoutScale int64 = 100_000_000

type ModelTokenEarning struct {
	ProviderEarning
	FractionalMicroUSD int64
}

// Called under the same transaction/lock as reservation finalization. Never
// mutate the caller's earning: retries can share it across goroutines.
func carryModelTokenEarning(earning *ModelTokenEarning, carry int64) (*ProviderEarning, int64, error) {
	if earning == nil {
		return nil, carry, nil
	}
	if carry < 0 || carry >= ModelTokenPayoutScale || earning.FractionalMicroUSD < 0 || earning.FractionalMicroUSD >= ModelTokenPayoutScale {
		return nil, carry, fmt.Errorf("%w: invalid payout remainder", ErrPromotionInvalidSettlement)
	}
	result := earning.ProviderEarning
	sum := carry + earning.FractionalMicroUSD
	result.AmountMicroUSD += sum / ModelTokenPayoutScale
	return &result, sum % ModelTokenPayoutScale, nil
}
