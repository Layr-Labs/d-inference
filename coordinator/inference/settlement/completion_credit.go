package settlement

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s Service) creditCompletion(providerID string, provider *registry.Provider, pr *registry.PendingRequest, msg *protocol.InferenceCompleteMessage, price completionPrice) {
	totalCost, providerPayout := price.totalCost, price.providerPayout
	feePercent, freeSelfRoute := price.feePercent, price.freeSelfRoute

	// Resolve provider identity for payout.
	p := s.deps.Providers().GetProvider(providerID)
	if p == nil {
		p = provider
	}

	// Compute platform fee (needs referral lookup before spawning goroutines).
	platformFee := payments.PlatformFeeWithPercent(totalCost, feePercent)
	if platformFee > 0 {
		if referral := s.deps.Referral(); referral != nil {
			platformFee = referral.DistributeReferralReward(pr.ConsumerKey, platformFee, msg.RequestID)
		}
	}

	// Run provider credit and platform fee credit concurrently —
	// they target different accounts so there is no data dependency.
	var settlementWg sync.WaitGroup

	// Credit the provider's linked account (if any).
	if p != nil {
		p.Mu().Lock()
		accountID := p.AccountID
		publicKey := p.PublicKey
		p.Mu().Unlock()

		// Credit the provider only when there is an actual payout. A zero
		// payout means either free self-route (consumer == provider account)
		// or an uncollected charge (e.g. a self-route paid-fallback whose
		// owner had no balance) — in both cases we must not record a
		// (zero-value) earning row. Mirrors the platformFee > 0 guard below.
		if accountID != "" && !freeSelfRoute && providerPayout > 0 {
			settlementWg.Add(1)
			go func() {
				defer settlementWg.Done()
				start := time.Now()
				if err := s.deps.Store().CreditProviderAccount(&store.ProviderEarning{
					AccountID:        accountID,
					ProviderID:       providerID,
					ProviderKey:      publicKey,
					JobID:            msg.RequestID,
					Model:            pr.Model,
					AmountMicroUSD:   providerPayout,
					PromptTokens:     msg.Usage.PromptTokens,
					CompletionTokens: msg.Usage.CompletionTokens,
					CreatedAt:        time.Now(),
				}); err != nil {
					s.deps.Logger.Error("failed to credit linked provider account",
						"provider_id", providerID,
						"account_id", accountID,
						"request_id", msg.RequestID,
						"error", err,
					)
				}
				s.deps.Metrics.Histogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:provider_account_credit"})
				s.deps.Metrics.Count("billing.provider_credits_micro_usd", providerPayout, []string{"model:" + pr.Model, "type:account"})
			}()
		}
	}

	// Record platform fee.
	if platformFee > 0 {
		settlementWg.Add(1)
		go func() {
			defer settlementWg.Done()
			start := time.Now()
			// Financial: a failed platform-fee credit drops revenue accounting. Never swallow it.
			if err := s.deps.Store().Credit("platform", platformFee, store.LedgerPlatformFee, msg.RequestID); err != nil {
				s.deps.Logger.Error("failed to credit platform fee",
					"request_id", msg.RequestID, "platform_fee_micro_usd", platformFee, "error", err)
				s.deps.Metrics.Incr("billing.credit_failed", []string{"op:platform_fee"})
			}
			s.deps.Metrics.Histogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:platform_fee"})
			s.deps.Metrics.Count("billing.platform_fees_micro_usd", platformFee, []string{"model:" + pr.Model})
		}()
	}

	settlementWg.Wait()
}
