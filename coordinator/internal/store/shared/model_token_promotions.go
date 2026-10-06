package shared

import (
	"errors"
	"fmt"
	"math"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func PromotionQuote(quote store.ModelTokenQuote, free int64) (int64, int64, error) {
	if quote == nil {
		return 0, 0, errors.New("promotion quote is required")
	}
	gross, paid, err := quote(free)
	if err != nil {
		return 0, 0, err
	}
	if paid < 0 || gross < paid || gross > math.MaxInt64/2 {
		return 0, 0, errors.New("invalid promotion price")
	}
	return gross, paid, nil
}

func PromotionSettlement(r store.ModelTokenReservation, actual int64, quote store.ModelTokenQuote, earning *store.ModelTokenEarning) (store.ModelTokenReservation, error) {
	if actual < 0 {
		return r, fmt.Errorf("%w: negative token usage", store.ErrPromotionInvalidSettlement)
	}
	used := min(actual, r.FreeTokens)
	gross, paid, err := PromotionQuote(quote, used)
	if err != nil {
		return r, fmt.Errorf("%w: %v", store.ErrPromotionInvalidSettlement, err)
	}
	// A request minimum must never fund a payout without consuming tokens.
	// Zero-cost, zero-payout self-serving completions can still release holds.
	if actual == 0 && (gross > 0 || earning != nil && (earning.AmountMicroUSD > 0 || earning.FractionalMicroUSD > 0)) {
		return r, fmt.Errorf("%w: zero token usage cannot carry a charge or payout", store.ErrPromotionInvalidSettlement)
	}
	// Preserve the coordinator's fraud ceiling for provider-reported costs.
	if gross > 2*r.GrossReservedMicroUSD || paid > 2*r.ReservedMicroUSD && paid > 0 {
		return r, fmt.Errorf("%w: cost exceeds reservation ceiling", store.ErrPromotionInvalidSettlement)
	}
	if earning != nil && (earning.AccountID == "" || earning.JobID == "" || earning.AmountMicroUSD < 0 || earning.AmountMicroUSD > gross || earning.FractionalMicroUSD < 0 || earning.FractionalMicroUSD >= store.ModelTokenPayoutScale || earning.AmountMicroUSD == gross && earning.FractionalMicroUSD > 0) {
		return r, fmt.Errorf("%w: invalid provider earning", store.ErrPromotionInvalidSettlement)
	}
	r.State, r.UsedTokens, r.ConsumerCostMicroUSD = "settled", used, paid
	r.SponsoredMicroUSD = gross - paid
	return r, nil
}
