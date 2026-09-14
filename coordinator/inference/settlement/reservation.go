package settlement

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func reservationMetricMode(service bool) string {
	if service {
		return "service_hold"
	}
	return "ledger"
}

func (s Service) useServiceReservation(accountID string) bool {
	return s.deps.ServiceHolds != nil && s.deps.ServiceHolds.Enabled() && s.isServiceConsumer(accountID)
}

func (s Service) Reserve(accountID, model string, amount int64) (bool, error) {
	serviceMode := s.useServiceReservation(accountID)
	start := time.Now()
	if serviceMode {
		if err := s.deps.ServiceHolds.Reserve(accountID, amount); err != nil {
			s.deps.Metrics.Incr("billing.reservations", []string{"model:" + model, "mode:service_hold", "outcome:rejected"})
			return true, err
		}
		s.deps.Metrics.Incr("billing.reservations", []string{"model:" + model, "mode:service_hold", "outcome:reserved"})
		s.deps.Metrics.Histogram("billing.reserved_micro_usd", float64(amount), []string{"model:" + model, "mode:service_hold"})
		return true, nil
	}
	if err := s.deps.Ledger.Charge(accountID, amount, "reserve:"+accountID); err != nil {
		s.deps.Metrics.Incr("billing.reservations", []string{"model:" + model, "mode:ledger", "outcome:rejected"})
		return false, err
	}
	s.deps.Metrics.Incr("billing.reservations", []string{"model:" + model, "mode:ledger", "outcome:reserved"})
	s.deps.Metrics.Histogram("billing.reserved_micro_usd", float64(amount), []string{"model:" + model, "mode:ledger"})
	s.deps.Metrics.Histogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reserve"})
	return false, nil
}

func (s Service) Release(accountID, model string, amount int64, serviceMode bool) {
	if amount <= 0 {
		return
	}
	tags := []string{"model:" + model, "mode:" + reservationMetricMode(serviceMode)}
	if serviceMode {
		s.deps.ServiceHolds.Release(accountID, amount)
		s.deps.Metrics.Incr("billing.reservation_releases", append(tags, "reason:early"))
		return
	}
	start := time.Now()
	_ = s.deps.Store().Credit(accountID, amount, store.LedgerRefund, "reservation_refund")
	s.deps.Metrics.Incr("billing.reservation_refunds", tags)
	s.deps.Metrics.Incr("billing.reservation_releases", append(tags, "reason:early"))
	s.deps.Metrics.Histogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
}

func (s Service) releaseServiceReservation(pr *registry.PendingRequest, reason string) {
	if pr == nil || !pr.ServiceReservation {
		return
	}
	s.deps.ServiceHolds.Release(pr.ConsumerKey, pr.ReservedMicroUSD)
	if reason == "" {
		reason = "unknown"
	}
	s.deps.Metrics.Incr("billing.reservation_releases", []string{"model:" + pr.Model, "mode:service_hold", "reason:" + reason})
}
