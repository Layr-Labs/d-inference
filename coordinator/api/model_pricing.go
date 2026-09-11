package api

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// modelPriceInput is the price triple every price writer accepts — the admin
// platform price (PUT /v1/admin/pricing), a provider's own custom price
// (PUT /v1/pricing) and model registration (POST /v1/admin/models/register).
// All values are micro-USD per 1M tokens. cache_read_price is optional: when
// omitted the row stores no cache-read rate and billing derives it from the
// input price (payments.DefaultCacheReadPrice); an explicit 0 makes cached
// prompt tokens free.
type modelPriceInput struct {
	InputPrice     int64  `json:"input_price"`
	OutputPrice    int64  `json:"output_price"`
	CacheReadPrice *int64 `json:"cache_read_price,omitempty"`
}

// validate enforces input_price > 0, output_price > 0 and, when set,
// 0 <= cache_read_price <= input_price. A cache read priced above the uncached
// rate would charge the consumer more for a hit it never asked for, so it is
// rejected rather than clamped.
func (in modelPriceInput) validate() error {
	if in.InputPrice <= 0 || in.OutputPrice <= 0 {
		return fmt.Errorf("input_price and output_price must be positive (micro-USD per 1M tokens)")
	}
	if in.CacheReadPrice != nil && (*in.CacheReadPrice < 0 || *in.CacheReadPrice > in.InputPrice) {
		return fmt.Errorf("cache_read_price must be between 0 and input_price (micro-USD per 1M tokens)")
	}
	return nil
}

// modelPrice is the store row for this input under the given account.
func (in modelPriceInput) modelPrice(accountID, model string) store.ModelPrice {
	return store.ModelPrice{
		AccountID:      accountID,
		Model:          model,
		InputPrice:     in.InputPrice,
		OutputPrice:    in.OutputPrice,
		CacheReadPrice: in.CacheReadPrice,
	}
}

// modelPriceQuote renders a price row at its effective settlement rates. The
// cache-read rate is the one billing will use, derived when the row sets none.
func modelPriceQuote(price store.ModelPrice) types.ModelPriceQuote {
	return ratesQuote(payments.RatesFor(price, true))
}

func ratesQuote(rates payments.Rates) types.ModelPriceQuote {
	return types.ModelPriceQuote{
		InputPrice:     rates.Input,
		OutputPrice:    rates.Output,
		CacheReadPrice: rates.CacheRead,
		InputUSD:       payments.FormatPerMillionUSD(rates.Input),
		OutputUSD:      payments.FormatPerMillionUSD(rates.Output),
		CacheReadUSD:   payments.FormatPerMillionUSD(rates.CacheRead),
	}
}
