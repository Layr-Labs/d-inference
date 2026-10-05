package inference

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// completionFinancials snapshots the payout recipient before a failed consumer
// settlement is queued. Recovery never re-resolves ownership or sends a second
// terminal response, and downstream accounting runs only once per live job.
func (s *Owner) completionFinancials(pr *registry.PendingRequest, provider *registry.Provider, usage protocol.UsageInfo, feePercent *int64, freeSelf bool, accounting func(int64)) func(int64) {
	earning := store.ProviderEarning{JobID: pr.RequestID, Model: pr.Model, PromptTokens: usage.PromptTokens, CompletionTokens: usage.CompletionTokens, CreatedAt: time.Now()}
	if provider != nil {
		if current := s.registry.GetProvider(provider.ID); current != nil {
			provider = current
		}
		provider.Mu().Lock()
		earning.AccountID, earning.ProviderID, earning.ProviderKey = provider.AccountID, provider.ID, provider.PublicKey
		provider.Mu().Unlock()
	}
	if feePercent != nil {
		copied := *feePercent
		feePercent = &copied
	}
	var once sync.Once
	return func(cost int64) {
		once.Do(func() {
			var wg sync.WaitGroup
			wg.Add(1)
			go func() { defer wg.Done(); accounting(cost) }()
			defer wg.Wait()
			earning.AmountMicroUSD = payments.ProviderPayoutWithPercent(cost, feePercent)
			if earning.AccountID == "" || freeSelf || earning.AmountMicroUSD <= 0 {
				return
			}
			started := time.Now()
			if err := s.store.CreditProviderAccount(&earning); err != nil {
				s.logger.Error("failed to credit linked provider account", "provider_id", earning.ProviderID, "account_id", earning.AccountID, "request_id", earning.JobID, "error", err)
			}
			s.observation.Histogram("store.credit.latency_ms", float64(time.Since(started).Milliseconds()), []string{"op:provider_account_credit"})
			s.observation.Count("billing.provider_credits_micro_usd", earning.AmountMicroUSD, []string{"model:" + earning.Model, "type:account"})
		})
	}
}
