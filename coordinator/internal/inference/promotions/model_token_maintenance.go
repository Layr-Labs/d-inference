package promotions

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Live requests renew their durable token/cash holds. A crashed coordinator's
// holds are refunded after ten minutes without renewal. A closed reservation
// can never settle or be revived by a late heartbeat/provider terminal.
const modelTokenLeaseTimeout = 10 * time.Minute

func (s *Engine) Run(ctx context.Context) {
	_, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		return
	}
	timer := time.NewTicker(30 * time.Second)
	defer timer.Stop()
	for {
		s.Maintain(time.Now())
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
	}
}

func (s *Engine) maintain(backend store.ModelTokenPromotionStore, now time.Time) {
	s.settlements.Range(func(key, value any) bool {
		_, _ = s.reconcile(key.(string))
		return true
	})
	s.refunds.Range(func(key, value any) bool { _, _ = s.Release(key.(string)); return true })
	var ids []string
	s.active.Range(func(key, value any) bool { ids = append(ids, key.(string)); return true })
	if err := backend.RenewModelTokenReservations(ids, now); err != nil {
		s.logger.Error("promotion reservation renewal failed", "error", err)
		return
	}
	if _, err := backend.ReleaseStaleModelTokenReservations(now.Add(-modelTokenLeaseTimeout)); err != nil {
		s.logger.Error("promotion orphan recovery failed", "error", err)
	}
}

// reconcile retries one selected terminal using its durable reservation identity.
// attempted is false when there is no outstanding settlement to retry.
func (s *Engine) reconcile(id string) (attempted bool, err error) {
	attempted, err = s.RetrySettlement(id)
	if !attempted {
		return false, nil
	}
	if err == nil {
		s.settlements.Delete(id)
		s.active.Delete(id)
	}
	return true, err
}

// RetrySettlement executes a queued terminal without retiring its lease.
// Maintenance retires successful retries only after the store acknowledges them.
func (s *Engine) RetrySettlement(id string) (attempted bool, err error) {
	retry, pending := s.settlements.Load(id)
	if !pending {
		return false, nil
	}
	return true, retry.(func() error)()
}

func (s *Engine) Maintain(now time.Time) {
	if backend, ok := store.As[store.ModelTokenPromotionStore](s.store); ok {
		s.maintain(backend, now)
	}
}
