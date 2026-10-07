package promotions

import (
	"errors"
	"math"
	"math/big"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Sponsored prices have no request minimum or rounding-up floor. Keep exact
// fractional provider earnings until the store carries them across requests.
type Price struct {
	Gross, Paid, Payout, Remainder int64
}

// Promotion settlement prices every prompt token at rates.Input: cached prompt
// tokens get no cache-read discount on this path (which prompt tokens a grant's
// free tokens cover, and at which rate the sponsor values them, is unresolved).
func PriceTokens(prompt, completion int, rates payments.Rates, free int64, fee *int64) (Price, error) {
	if prompt < 0 || completion < 0 || free < 0 {
		return Price{}, errors.New("negative token count")
	}
	in, out := rates.Input, rates.Output
	if in < 0 || out < 0 {
		return Price{}, errors.New("negative token price")
	}
	freeIn := min(int64(prompt), free)
	freeOut := min(int64(completion), free-freeIn)
	paidIn, paidOut := int64(prompt)-freeIn, int64(completion)-freeOut
	// big.Int prevents overflow before bounds checking (provider usage is untrusted).
	value := func(input, output int64) *big.Int {
		return new(big.Int).Add(new(big.Int).Mul(big.NewInt(input), big.NewInt(in)), new(big.Int).Mul(big.NewInt(output), big.NewInt(out)))
	}
	paid := new(big.Int)
	if paidIn > 0 || paidOut > 0 {
		paid.Add(new(big.Int).Quo(value(paidIn, 0), big.NewInt(1_000_000)), new(big.Int).Quo(value(0, paidOut), big.NewInt(1_000_000)))
		if paid.Cmp(big.NewInt(payments.MinimumCharge())) < 0 {
			paid.SetInt64(payments.MinimumCharge())
		}
	}
	sponsored := value(freeIn, freeOut)
	// Gross is a conservative whole-micro-dollar reservation/validation bound,
	// never the payout. Only the exact numerator below funds sponsored earnings.
	gross := new(big.Int).Add(paid, new(big.Int).Quo(new(big.Int).Add(sponsored, big.NewInt(999_999)), big.NewInt(1_000_000)))
	if prompt == 0 && completion == 0 {
		gross.SetInt64(payments.MinimumCharge())
	} // rejected by settlement's zero-usage guard
	if !gross.IsInt64() || gross.Int64() > math.MaxInt64/2 {
		return Price{}, errors.New("promotion price overflow")
	}
	share := payments.ProviderPayoutWithPercent(100, fee)
	exactPayout := new(big.Int).Mul(sponsored, big.NewInt(share))
	whole, remainder := new(big.Int), new(big.Int)
	whole.QuoRem(exactPayout, big.NewInt(store.ModelTokenPayoutScale), remainder)
	paidFee := new(big.Int).Quo(new(big.Int).Mul(paid, big.NewInt(100-share)), big.NewInt(100))
	whole.Add(whole, new(big.Int).Sub(paid, paidFee))
	if !whole.IsInt64() {
		return Price{}, errors.New("promotion payout overflow")
	}
	return Price{Gross: gross.Int64(), Paid: paid.Int64(), Payout: whole.Int64(), Remainder: remainder.Int64()}, nil
}
