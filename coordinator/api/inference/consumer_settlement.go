package inference

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) settleCompletedConsumer(pr *registry.PendingRequest, cost int64, feePercent *int64, freeSelfRoute bool, complete func(int64)) (bool, int64, int64) {
	reserved := pr.ReservedMicroUSD
	if pr.ServiceReservation {
		reserved = 0 // service reservations hold capacity without debiting cash
	}
	in := store.ConsumerChargeSettlement{
		AccountID: pr.ConsumerKey, JobID: pr.RequestID,
		ReservedMicroUSD: reserved, CostMicroUSD: cost,
		ReferralEnabled: s.billing != nil && s.billing.Referral() != nil && !freeSelfRoute,
	}
	// Snapshot accounting and hold values retained by reconciliation.
	model, service := pr.Model, pr.ServiceReservation
	held := pr.ReservedMicroUSD
	platformCovered := pr.ReservedMicroUSD == 0 && !pr.FreeSelfRoute && !service
	settledCost := func(result store.ConsumerChargeResult) int64 {
		if result.Uncollected && platformCovered {
			return cost
		}
		return result.CollectedMicroUSD
	}
	started := time.Now()
	finalized, result, err := s.consumerCharges.Settle(pr, s.store, in, func(result store.ConsumerChargeResult) {
		// Unknown settlement outcomes still own the service funds. Releasing
		// early lets a later request spend them before reconciliation charges.
		if service {
			s.reservations.ReleaseService(in.AccountID, model, held, "finalize")
		}
		charged := settledCost(result)
		if result.Uncollected {
			s.observation.Incr("billing.uncollected_zeroed", []string{"model:" + model})
		}
		if result.ReferralRewardMicroUSD > 0 && result.Applied {
			s.observation.Incr("billing.referral_rewards", nil)
			s.observation.Histogram("billing.referral_reward_micro_usd", float64(result.ReferralRewardMicroUSD), nil)
		}
		if charged < cost && reserved > 0 {
			s.observation.Incr("billing.cost_clamped", []string{"model:" + model})
		}
		if service && !result.Uncollected {
			s.observation.Incr("billing.reservation_finalize", []string{"model:" + model, "mode:service_hold", "outcome:charged"})
			s.observation.Histogram("billing.service_settlement_micro_usd", float64(charged), []string{"model:" + model})
		} else if reserved > charged {
			s.observation.Histogram("billing.settlement_refund_micro_usd", float64(reserved-charged), []string{"model:" + model})
		} else if reserved > 0 && charged > reserved {
			s.observation.Incr("billing.overage_charged", []string{"model:" + model})
			s.observation.Histogram("billing.overage_micro_usd", float64(charged-reserved), []string{"model:" + model})
		}
		complete(charged)
	})
	s.observation.Histogram("billing.consumer_settlement.latency_ms", float64(time.Since(started).Milliseconds()), nil)
	if err != nil {
		s.logger.Error("consumer settlement queued for reconciliation", "request_id", in.JobID, "consumer_key", in.AccountID, "reserved_micro_usd", reserved, "cost_micro_usd", cost, "error", err)
		s.observation.Incr("billing.consumer_settlement_failed", []string{"model:" + model})
		return false, 0, 0
	}
	charged := settledCost(result)
	return finalized, charged, payments.ProviderPayoutWithPercent(charged, feePercent)
}
