package settlement

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// RefundProviderExtra refunds the provider-specific surcharge charged on top of
// the shared base reservation when an attempt is abandoned. It is idempotent:
// after refunding it resets ReservedMicroUSD to the base so a second call (or a
// later settlement) cannot double-refund. The shared base is never refunded
// here — that is handled once by Refund (full failure) or by the
// winning attempt's settlement.
func (s Service) RefundProviderExtra(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	extra := pr.ReservedMicroUSD - pr.BaseReservedMicroUSD
	if extra <= 0 {
		return
	}
	_ = s.deps.Store().Credit(pr.ConsumerKey, extra, store.LedgerRefund, "reservation_extra_refund:"+pr.RequestID)
	pr.ReservedMicroUSD = pr.BaseReservedMicroUSD
	s.deps.Metrics.Incr("billing.reservation_extra_refunds", []string{"model:" + pr.Model})
}

func (s Service) Refund(pr *registry.PendingRequest, reference string) bool {
	if pr == nil || pr.ReservedMicroUSD <= 0 {
		return false
	}
	if reference == "" {
		reference = "reservation_refund:" + pr.RequestID
	}
	start := time.Now()
	finalized, err := pr.FinalizeReservation(func() error {
		if pr.ServiceReservation {
			s.releaseServiceReservation(pr, "refund")
			return nil
		}
		return s.deps.Store().Credit(pr.ConsumerKey, pr.ReservedMicroUSD, store.LedgerRefund, reference)
	})
	if err != nil {
		s.deps.Logger.Error("failed to refund reservation",
			"request_id", pr.RequestID,
			"consumer_key", pr.ConsumerKey,
			"reserved_micro_usd", pr.ReservedMicroUSD,
			"error", err,
		)
		return false
	}
	if !finalized {
		return false
	}
	tags := []string{"model:" + pr.Model, "mode:" + reservationMetricMode(pr.ServiceReservation)}
	s.deps.Metrics.Incr("billing.reservation_refunds", tags)
	if !pr.ServiceReservation {
		s.deps.Metrics.Incr("billing.reservation_releases", append(tags, "reason:refund"))
		s.deps.Metrics.Histogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
	}
	return true
}
