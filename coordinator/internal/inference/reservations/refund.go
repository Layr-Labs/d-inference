package reservations

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Controller) Refund(pr *registry.PendingRequest, reference string) bool {
	if pr != nil && pr.ModelTokenReservationID != "" {
		finalized, err := pr.FinalizeReservation(func() error { _, e := s.promotions.Release(pr.ModelTokenReservationID); return e })
		if err != nil {
			s.logger.Error("promotion refund failed", "reservation_id", pr.ModelTokenReservationID, "error", err)
		}
		return finalized && err == nil
	}
	if pr == nil || pr.ReservedMicroUSD <= 0 {
		return false
	}
	if reference == "" {
		reference = "reservation_refund:" + pr.RequestID
	}
	start := time.Now()
	finalized, err := pr.FinalizeReservation(func() error {
		if pr.ServiceReservation {
			s.ReleaseService(pr, "refund")
			return nil
		}
		return s.store.Credit(pr.ConsumerKey, pr.ReservedMicroUSD, store.LedgerRefund, reference)
	})
	if err != nil {
		s.logger.Error("failed to refund reservation",
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
	s.observation.Incr("billing.reservation_refunds", tags)
	if !pr.ServiceReservation {
		s.observation.Incr("billing.reservation_releases", append(tags, "reason:refund"))
		s.observation.Histogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
	}
	return true
}
