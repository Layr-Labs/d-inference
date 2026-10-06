package reservations

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Controller) providerCost(provider *registry.Provider, model string, promptTokens, maxTokens int) int64 {
	accountID := ""
	if provider != nil {
		provider.Mu().Lock()
		accountID = provider.AccountID
		provider.Mu().Unlock()
	}
	if accountID != "" {
		if price, ok := s.store.GetModelPrice(accountID, model); ok {
			return payments.RatesFor(price, true).CostWithMinimum(payments.Usage{PromptTokens: promptTokens, CompletionTokens: maxTokens})
		}
	}
	return s.Cost(model, promptTokens, maxTokens)
}

// ReserveAdditionalForProvider runs after selection and before any provider
// write. The key cap covers the new total; only its delta is charged. Service
// consumers retain platform pricing and model-token requests keep quota holds.
func (s *Controller) ReserveAdditionalForProvider(pr *registry.PendingRequest, provider *registry.Provider) (int64, error) {
	if pr == nil {
		return 0, fmt.Errorf("pending request is required")
	}
	if pr.ModelTokenReservationID != "" {
		return s.promotions.TopUpProvider(pr, provider)
	}
	if s.isService(pr.ConsumerKey) {
		return pr.ReservedMicroUSD, nil
	}
	required := s.providerCost(provider, pr.Model, pr.EstimatedPromptTokens, pr.RequestedMaxTokens)
	if required <= pr.ReservedMicroUSD {
		return pr.ReservedMicroUSD, nil
	}
	if pr.KeyID != "" && pr.KeyLimitMicroUSD != nil {
		since := store.KeySpendWindowStart(pr.KeyLimitReset, time.Now())
		if s.store.KeySpendSince(pr.KeyID, since)+required > *pr.KeyLimitMicroUSD {
			return pr.ReservedMicroUSD, store.ErrInsufficientBalance
		}
	}
	extra := required - pr.ReservedMicroUSD
	if err := s.ledger.Charge(pr.ConsumerKey, extra, "reserve:"+pr.ConsumerKey); err != nil {
		return pr.ReservedMicroUSD, err
	}
	pr.ReservedMicroUSD = required
	s.observation.Histogram("billing.reserved_micro_usd", float64(required), []string{"model:" + pr.Model})
	return required, nil
}
