package pricing

import (
	"fmt"
	"math"
	"strings"

	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/store"
)

const (
	MaxProviderDiscountBPS = 9000
	basisPointsPerPercent  = 100
	fullPriceBPS           = 10000
)

type EffectivePrice struct {
	Model             string
	BaseInputPrice    int64
	BaseOutputPrice   int64
	InputPrice        int64
	OutputPrice       int64
	DiscountBPS       int
	DiscountPercent   float64
	DiscountScope     string
	DiscountModel     string
	DiscountProvider  string
	DiscountAccountID string
}

func DiscountBPSFromPercent(percent float64) (int, error) {
	if math.IsNaN(percent) || math.IsInf(percent, 0) {
		return 0, fmt.Errorf("discount_percent must be a finite number")
	}
	if percent < 0 || percent > float64(MaxProviderDiscountBPS)/basisPointsPerPercent {
		return 0, fmt.Errorf("discount_percent must be between 0 and 90")
	}
	return int(math.Round(percent * basisPointsPerPercent)), nil
}

func DiscountPercentFromBPS(bps int) float64 {
	return float64(bps) / basisPointsPerPercent
}

func PlatformPrice(st store.Store, model string) (int64, int64) {
	model = strings.TrimSpace(model)
	if st != nil {
		if input, output, ok := st.GetModelPrice("platform", model); ok {
			return input, output
		}
	}
	return payments.InputPricePerMillion(model), payments.OutputPricePerMillion(model)
}

func ResolveDiscount(st store.Store, accountID, providerKey, model string) (store.ProviderDiscount, bool) {
	if st == nil || strings.TrimSpace(accountID) == "" {
		return store.ProviderDiscount{}, false
	}
	accountID = strings.TrimSpace(accountID)
	providerKey = strings.TrimSpace(providerKey)
	model = strings.TrimSpace(model)

	if providerKey != "" {
		if model != "" {
			if d, ok := st.GetProviderDiscount(accountID, providerKey, model); ok {
				return d, true
			}
		}
		if d, ok := st.GetProviderDiscount(accountID, providerKey, ""); ok {
			return d, true
		}
	}
	if model != "" {
		if d, ok := st.GetProviderDiscount(accountID, "", model); ok {
			return d, true
		}
	}
	return st.GetProviderDiscount(accountID, "", "")
}

func EffectiveModelPrice(st store.Store, accountID, providerKey, model string) EffectivePrice {
	baseInput, baseOutput := PlatformPrice(st, model)
	ep := EffectivePrice{
		Model:           model,
		BaseInputPrice:  baseInput,
		BaseOutputPrice: baseOutput,
		InputPrice:      baseInput,
		OutputPrice:     baseOutput,
	}
	if d, ok := ResolveDiscount(st, accountID, providerKey, model); ok {
		ep.DiscountBPS = d.DiscountBPS
		ep.DiscountPercent = DiscountPercentFromBPS(d.DiscountBPS)
		ep.DiscountAccountID = d.AccountID
		ep.DiscountProvider = d.ProviderKey
		ep.DiscountModel = d.Model
		ep.DiscountScope = d.Scope()
		ep.InputPrice = applyDiscount(baseInput, d.DiscountBPS)
		ep.OutputPrice = applyDiscount(baseOutput, d.DiscountBPS)
	}
	return ep
}

func CalculateCost(st store.Store, accountID, providerKey, model string, promptTokens, completionTokens int) int64 {
	ep := EffectiveModelPrice(st, accountID, providerKey, model)
	return payments.CalculateCostWithOverrides(model, promptTokens, completionTokens, ep.InputPrice, ep.OutputPrice, true)
}

func applyDiscount(price int64, discountBPS int) int64 {
	if discountBPS <= 0 {
		return price
	}
	discounted := price * int64(fullPriceBPS-discountBPS) / fullPriceBPS
	if price > 0 && discounted < 1 {
		return 1
	}
	return discounted
}
