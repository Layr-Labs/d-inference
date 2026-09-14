package settlement

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type completionPrice struct {
	feePercent                *int64
	totalCost, providerPayout int64
	freeSelfRoute             bool
	startedAt                 time.Time
}

// Result carries the final accounting amounts for the caller's completion log.
type Result struct {
	CostMicroUSD           int64
	ProviderPayoutMicroUSD int64
}

// Complete settles an already-claimed provider terminal. afterUsageRecorded runs
// after usage publication and before referral distribution or payout credits;
// the API uses that point for its existing outcome and latency observations.
// The caller signals consumer channels only after this method returns.
func (s Service) Complete(providerID string, provider *registry.Provider, pr *registry.PendingRequest, msg *protocol.InferenceCompleteMessage, afterUsageRecorded func(totalCost int64)) Result {
	price := s.priceCompletion(providerID, provider, pr, msg)
	price, finalized := s.finalizeCompletion(providerID, pr, msg, price)
	if finalized {
		s.recordCompletionUsage(providerID, pr, msg, price.totalCost, price.freeSelfRoute)
		if afterUsageRecorded != nil {
			afterUsageRecorded(price.totalCost)
		}
		s.creditCompletion(providerID, provider, pr, msg, price)
		if ap := pr.Profile; ap != nil {
			ap.SettleDBUS.Add(time.Since(price.startedAt).Microseconds())
		}
	}
	return Result{CostMicroUSD: price.totalCost, ProviderPayoutMicroUSD: price.providerPayout}
}
