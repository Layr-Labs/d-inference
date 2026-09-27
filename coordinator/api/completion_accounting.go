package api

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// completionAccounting snapshots the metadata needed after settlement. Both the
// initial completion and an ambiguous-commit retry use this same one-shot callback,
// with the consumer cost recovered from the durable settlement. It deliberately
// does not replay provider credits, consumer signalling, or routing latency metrics.
func (s *Server) completionAccounting(pr *registry.PendingRequest, providerID string, usage protocol.UsageInfo, feePercent *int64, freeSelfRoute bool) func(int64) {
	consumerKey, keyID, model := pr.ConsumerKey, pr.KeyID, pr.Model
	publicModel, requestID := consumerModel(pr), pr.RequestID
	completedAt := time.Now()
	var location *store.ProviderLocation
	if pr.ConsumerLocation != nil {
		copy := *pr.ConsumerLocation
		location = &copy
	}
	if feePercent != nil {
		copy := *feePercent
		feePercent = &copy
	}
	var once sync.Once
	return func(totalCost int64) {
		once.Do(func() {
			// Record in-memory usage (for current session queries).
			s.ledger.RecordUsage(consumerKey, payments.UsageEntry{
				JobID:            requestID,
				Model:            publicModel,
				PromptTokens:     usage.PromptTokens,
				CompletionTokens: usage.CompletionTokens,
				CostMicroUSD:     totalCost,
				Timestamp:        completedAt,
			})

			// Persist usage to DB asynchronously — billing has already been
			// settled above, so this INSERT is not on the critical path. KeyID
			// carries per-key usage/spend attribution (empty for legacy callers).
			//
			// Skip the persistent (public-stats-feeding) row for FREE self-route:
			// it is private, owner-only traffic and must not appear in the public
			// /stats time-series, request-location, or flow aggregations. Private-only
			// providers only ever serve free self-route, so this also keeps their
			// traffic out of public stats. The owner still sees it via the in-memory
			// RecordUsage above (their session/transparency view).
			if !freeSelfRoute {
				saferun.Go(s.logger, "recordUsage", func() {
					s.store.RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, publicModel, requestID, usage.PromptTokens, usage.CompletionTokens, totalCost, location)
				})
			}

			// Distribute the referral share of the collected consumer fee.
			platformFee := payments.PlatformFeeWithPercent(totalCost, feePercent)
			if platformFee > 0 && s.billing != nil && s.billing.Referral() != nil {
				platformFee = s.billing.Referral().DistributeReferralReward(consumerKey, platformFee, requestID)
			}

			// Record platform fee.
			if platformFee > 0 {
				start := time.Now()
				// Financial: a failed platform-fee credit drops revenue accounting. Never swallow it.
				if err := s.store.Credit("platform", platformFee, store.LedgerPlatformFee, requestID); err != nil {
					s.logger.Error("failed to credit platform fee",
						"request_id", requestID, "platform_fee_micro_usd", platformFee, "error", err)
					s.ddIncr("billing.credit_failed", []string{"op:platform_fee"})
				}
				s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:platform_fee"})
				s.ddCount("billing.platform_fees_micro_usd", platformFee, []string{"model:" + model})
			}
		})
	}
}
