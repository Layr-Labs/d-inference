package shared

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Called under the same transaction/lock as reservation finalization. Never
// mutate the caller's earning: retries can share it across goroutines.
func CarryModelTokenEarning(earning *store.ModelTokenEarning, carry int64) (*store.ProviderEarning, int64, error) {
	if earning == nil {
		return nil, carry, nil
	}
	if carry < 0 || carry >= store.ModelTokenPayoutScale || earning.FractionalMicroUSD < 0 || earning.FractionalMicroUSD >= store.ModelTokenPayoutScale {
		return nil, carry, fmt.Errorf("%w: invalid payout remainder", store.ErrPromotionInvalidSettlement)
	}
	result := earning.ProviderEarning
	sum := carry + earning.FractionalMicroUSD
	result.AmountMicroUSD += sum / store.ModelTokenPayoutScale
	return &result, sum % store.ModelTokenPayoutScale, nil
}
