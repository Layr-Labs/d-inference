package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Live requests renew their durable token/cash holds. A crashed coordinator's
// holds are refunded after ten minutes without renewal. A closed reservation
// can never settle or be revived by a late heartbeat/provider terminal.
const modelTokenLeaseTimeout = 10 * time.Minute

func (s *Server) runModelTokenMaintenance(ctx context.Context) {
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		return
	}
	timer := time.NewTicker(30 * time.Second)
	defer timer.Stop()
	for {
		s.maintainModelTokens(backend, time.Now())
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
	}
}

func (s *Server) maintainModelTokens(backend store.ModelTokenPromotionStore, now time.Time) {
	s.modelTokenSettlements.Range(func(key, value any) bool {
		if err := value.(func() error)(); err == nil {
			s.modelTokenSettlements.Delete(key)
			s.modelTokenActive.Delete(key)
		}
		return true
	})
	s.modelTokenRefunds.Range(func(key, value any) bool { _, _ = s.releaseModelTokenReservation(key.(string)); return true })
	var ids []string
	s.modelTokenActive.Range(func(key, value any) bool { ids = append(ids, key.(string)); return true })
	if err := backend.RenewModelTokenReservations(ids, now); err != nil {
		s.logger.Error("promotion reservation renewal failed", "error", err)
		return
	}
	if _, err := backend.ReleaseStaleModelTokenReservations(now.Add(-modelTokenLeaseTimeout)); err != nil {
		s.logger.Error("promotion orphan recovery failed", "error", err)
	}
}
