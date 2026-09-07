package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// settleCompletedConsumer keeps the existing reservation ownership gate while
// moving the consumer balance delta and referral reward into one store commit.
// Provider/platform credits remain downstream of a successful settlement.
func (s *Server) settleCompletedConsumer(pr *registry.PendingRequest, cost int64, feePercent *int64, freeSelfRoute bool) (bool, int64, int64) {
	reserved := pr.ReservedMicroUSD
	if pr.ServiceReservation {
		reserved = 0 // service reservation is an in-memory hold, not a debit
	}
	in := store.ConsumerChargeSettlement{
		AccountID: pr.ConsumerKey, JobID: pr.RequestID,
		ReservedMicroUSD: reserved, CostMicroUSD: cost,
		ReferralEnabled: s.billing != nil && s.billing.Referral() != nil && !freeSelfRoute,
	}
	var result store.ConsumerChargeResult
	var settleErr error
	retried := false
	started := time.Now()
	finalized, err := pr.FinalizeReservation(func() error {
		// Retrying is safe even if COMMIT succeeded but its response was lost:
		// the durable job row returns the already-applied financial result.
		for attempt := 0; attempt < 3; attempt++ {
			result, settleErr = s.store.FinalizeConsumerCharge(in)
			if settleErr == nil {
				return nil
			}
			retried = true
		}
		// Seal the reservation while still holding its lock. After a network
		// failure we cannot distinguish rollback from a committed transaction
		// whose response was lost; generic timeout/defer refunds must not give
		// the consumer back money that has already earned a referral reward.
		return nil
	})
	s.ddHistogram("billing.consumer_settlement.latency_ms", float64(time.Since(started).Milliseconds()), nil)
	if settleErr != nil {
		// Do not independently refund here: an unknown COMMIT outcome may have
		// already settled the consumer and rewarded the referrer. Keep the
		// reservation fenced and surface the exact request for reconciliation.
		s.logger.Error("consumer settlement failed; financial reconciliation required",
			"request_id", pr.RequestID, "consumer_key", pr.ConsumerKey,
			"reserved_micro_usd", reserved, "cost_micro_usd", cost, "error", settleErr)
		s.ddIncr("billing.consumer_settlement_failed", []string{"model:" + pr.Model})
		if pr.ServiceReservation {
			s.releaseServiceReservation(pr, "settlement_unknown")
		}
		return false, 0, 0
	}
	if !finalized || err != nil {
		s.logger.Warn("skipping completion billing for already-finalized reservation", "request_id", pr.RequestID)
		return false, 0, 0
	}
	if pr.ServiceReservation {
		s.releaseServiceReservation(pr, "finalize")
	}
	// A new PendingRequest replay must not repeat downstream wallet/platform
	// credits. An in-call retry may be recovering this call's uncertain COMMIT,
	// so it still needs to complete those downstream operations.
	if !result.Applied && !retried {
		return false, result.CollectedMicroUSD, 0
	}
	settledCost := result.CollectedMicroUSD
	if result.Uncollected {
		s.ddIncr("billing.uncollected_zeroed", []string{"model:" + pr.Model})
		// Preserve legacy platform-covered/admin provider payouts. Such requests
		// have no collected spend in the settlement row and earn no referral.
		if pr.ReservedMicroUSD == 0 && !pr.FreeSelfRoute {
			settledCost = cost
		}
	}
	if result.ReferralRewardMicroUSD > 0 && result.Applied {
		s.ddIncr("billing.referral_rewards", nil)
		s.ddHistogram("billing.referral_reward_micro_usd", float64(result.ReferralRewardMicroUSD), nil)
	}
	if settledCost < cost && reserved > 0 {
		s.ddIncr("billing.cost_clamped", []string{"model:" + pr.Model})
	}
	if pr.ServiceReservation && !result.Uncollected {
		s.ddIncr("billing.reservation_finalize", []string{"model:" + pr.Model, "mode:service_hold", "outcome:charged"})
		s.ddHistogram("billing.service_settlement_micro_usd", float64(result.CollectedMicroUSD), []string{"model:" + pr.Model})
	} else if reserved > result.CollectedMicroUSD {
		s.ddHistogram("billing.settlement_refund_micro_usd", float64(reserved-result.CollectedMicroUSD), []string{"model:" + pr.Model})
	} else if reserved > 0 && result.CollectedMicroUSD > reserved {
		s.ddIncr("billing.overage_charged", []string{"model:" + pr.Model})
		s.ddHistogram("billing.overage_micro_usd", float64(result.CollectedMicroUSD-reserved), []string{"model:" + pr.Model})
	}
	return true, settledCost, payments.ProviderPayoutWithPercent(settledCost, feePercent)
}
