package settlement

import (
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s Service) finalizeCompletion(providerID string, pr *registry.PendingRequest, msg *protocol.InferenceCompleteMessage, price completionPrice) (completionPrice, bool) {
	totalCost, providerPayout := price.totalCost, price.providerPayout
	feePercent, freeSelfRoute := price.feePercent, price.freeSelfRoute

	billingFinalized := true

	// Settle billing against the pre-flight reservation. All balance
	// mutations (overage charge, refund) happen inside the finalization
	// gate so that a concurrent timeout/error refund path cannot race
	// with the settlement here.
	if pr.ServiceReservation && pr.ReservedMicroUSD > 0 {
		var chargeErr error
		finalized, _ := pr.FinalizeReservation(func() error {
			if totalCost > 0 {
				start := time.Now()
				chargeErr = s.deps.Ledger.Charge(pr.ConsumerKey, totalCost, msg.RequestID)
				s.deps.Metrics.Histogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:service_reservation_settle"})
			}
			s.releaseServiceReservation(pr, "finalize")
			return nil
		})
		if !finalized {
			billingFinalized = false
			s.deps.Logger.Warn("skipping completion billing for already-finalized service reservation",
				"provider_id", providerID,
				"request_id", msg.RequestID,
			)
		} else if chargeErr != nil {
			if errors.Is(chargeErr, store.ErrInsufficientBalance) {
				s.deps.Logger.Warn("service reservation settlement failed (insufficient balance) — zeroing uncollected charge",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
				)
			} else {
				s.deps.Logger.Error("service reservation settlement failed (DB error) — zeroing uncollected charge",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
					"error", chargeErr,
				)
			}
			totalCost = 0
			providerPayout = 0
			s.deps.Metrics.Incr("billing.uncollected_zeroed", []string{"model:" + pr.Model, "mode:service_hold"})
		} else {
			s.deps.Metrics.Incr("billing.reservation_finalize", []string{"model:" + pr.Model, "mode:service_hold", "outcome:charged"})
			s.deps.Metrics.Histogram("billing.service_settlement_micro_usd", float64(totalCost), []string{"model:" + pr.Model})
		}
	} else if pr.ReservedMicroUSD > 0 {
		if !pr.MarkReservationFinalized() {
			billingFinalized = false
			s.deps.Logger.Warn("skipping completion billing for already-finalized reservation",
				"provider_id", providerID,
				"request_id", msg.RequestID,
			)
		} else if totalCost > pr.ReservedMicroUSD {
			// Actual cost exceeds reservation (e.g. provider custom
			// pricing above platform rate). Attempt to charge the
			// consumer the difference. Cap overage at the reservation
			// amount as a fraud circuit-breaker — a provider cannot
			// bill more than 2x the pre-flight estimate.
			overage := totalCost - pr.ReservedMicroUSD
			if overage > pr.ReservedMicroUSD {
				s.deps.Logger.Error("overage exceeds reservation cap — clamping",
					"provider_id", providerID,
					"request_id", msg.RequestID,
					"reported_cost_micro_usd", totalCost,
					"reserved_micro_usd", pr.ReservedMicroUSD,
					"uncapped_overage_micro_usd", overage,
				)
				s.deps.Metrics.Incr("billing.cost_clamped", []string{"model:" + pr.Model})
				overage = pr.ReservedMicroUSD
				totalCost = pr.ReservedMicroUSD * 2
			}
			if err := s.deps.Ledger.Charge(pr.ConsumerKey, overage, "overage:"+msg.RequestID); err != nil {
				// Overage charge failed — clamp to reservation so
				// the provider still gets paid something.
				if errors.Is(err, store.ErrInsufficientBalance) {
					s.deps.Logger.Warn("overage charge failed (insufficient balance) — clamping to reservation",
						"provider_id", providerID,
						"request_id", msg.RequestID,
						"reported_cost_micro_usd", totalCost,
						"reserved_micro_usd", pr.ReservedMicroUSD,
						"overage_micro_usd", overage,
					)
				} else {
					s.deps.Logger.Error("overage charge failed (DB error) — clamping to reservation",
						"provider_id", providerID,
						"request_id", msg.RequestID,
						"reported_cost_micro_usd", totalCost,
						"reserved_micro_usd", pr.ReservedMicroUSD,
						"overage_micro_usd", overage,
						"error", err,
					)
				}
				s.deps.Metrics.Incr("billing.cost_clamped", []string{"model:" + pr.Model})
				totalCost = pr.ReservedMicroUSD
			} else {
				s.deps.Logger.Info("overage charged to consumer",
					"provider_id", providerID,
					"request_id", msg.RequestID,
					"overage_micro_usd", overage,
					"total_cost_micro_usd", totalCost,
				)
				s.deps.Metrics.Incr("billing.overage_charged", []string{"model:" + pr.Model})
				s.deps.Metrics.Histogram("billing.overage_micro_usd", float64(overage), []string{"model:" + pr.Model})
				pr.ReservedMicroUSD = totalCost
			}
			// Recompute payout after potential clamp.
			providerPayout = payments.ProviderPayoutWithPercent(totalCost, feePercent)
		} else if totalCost < pr.ReservedMicroUSD {
			refund := pr.ReservedMicroUSD - totalCost
			start := time.Now()
			// Financial: a failed refund over-charges the consumer. Never swallow it.
			if err := s.deps.Store().Credit(pr.ConsumerKey, refund, store.LedgerRefund, msg.RequestID); err != nil {
				s.deps.Logger.Error("failed to credit settlement refund to consumer",
					"request_id", msg.RequestID, "refund_micro_usd", refund, "error", err)
				s.deps.Metrics.Incr("billing.credit_failed", []string{"op:settlement_refund"})
			}
			s.deps.Metrics.Histogram("billing.settlement_refund_micro_usd", float64(refund), []string{"model:" + pr.Model})
			s.deps.Metrics.Histogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:settlement_refund"})
		}
	} else if !freeSelfRoute {
		start := time.Now()
		if err := s.deps.Ledger.Charge(pr.ConsumerKey, totalCost, msg.RequestID); err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				s.deps.Logger.Warn("could not charge consumer (insufficient balance)",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
				)
			} else {
				s.deps.Logger.Error("could not charge consumer (DB error)",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
					"error", err,
				)
			}
			// If this was a self-route request that FELL BACK to paid settlement
			// (marked free at dispatch, but mid-flight ownership revalidation
			// failed), the owner has no balance because self-route skips
			// reservation — so a failed charge means no money was collected and
			// we must NOT credit the provider from an unfunded balance. Zero the
			// cost and payout. (Other no-reservation paths — e.g. admin /
			// platform-covered usage — keep their existing payout behavior.)
			if pr.FreeSelfRoute {
				totalCost = 0
				providerPayout = 0
				s.deps.Metrics.Incr("billing.uncollected_zeroed", []string{"model:" + pr.Model})
			}
		}
		s.deps.Metrics.Histogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:charge"})
	}

	price.totalCost, price.providerPayout = totalCost, providerPayout
	return price, billingFinalized
}
