package memory

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"sort"
	"time"
)

func (s *MemoryStore) QueueStripeWithdrawal(id string, attempt int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return store.ErrNotFound
	}
	if w.Status != "pending" || w.TransferAttempt != attempt || w.TransferDispatchAttempts > 1 || w.Refunded || w.TransferID != "" || w.PayoutID != "" || w.SweepPayoutID != "" {
		return store.ErrPayoutConflict
	}
	w.Status = "queued"
	w.FailureReason = store.WithdrawalFundingReason
	w.TransferLeaseUntil = time.Time{}
	w.UpdatedAt = time.Now()
	return nil
}

func (s *MemoryStore) ClaimStripeWithdrawal(id string, now time.Time) (*store.StripeWithdrawal, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return nil, store.ErrNotFound
	}
	if !stripeQueueEligible(w, now) {
		return nil, nil
	}
	if w.Status == "queued" {
		w.TransferAttempt++
		w.TransferDispatchAttempts = 0
		w.TransferStartedAt = now
		w.Status = "pending"
		w.FailureReason = ""
	}
	w.TransferDispatchAttempts++
	w.TransferLeaseUntil = now.Add(5 * time.Minute)
	cp := *w
	return &cp, nil
}

func stripeQueueEligible(w *store.StripeWithdrawal, now time.Time) bool {
	return !w.Refunded && w.TransferID == "" && w.PayoutID == "" && w.SweepPayoutID == "" && !w.TransferLeaseUntil.After(now) && (w.Status == "queued" || (w.Status == "pending" && w.TransferAttempt > 0 && now.Sub(w.TransferStartedAt) < 12*time.Hour))
}

func (s *MemoryStore) ListStripeWithdrawalQueue(now time.Time, limit int) ([]store.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > 200 {
		limit = 200
	}
	rows := []store.StripeWithdrawal{}
	for _, w := range s.stripeWithdrawalsByID {
		if stripeQueueEligible(w, now) {
			rows = append(rows, *w)
		}
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].UpdatedAt.Before(rows[j].UpdatedAt) })
	if len(rows) > limit {
		rows = rows[:limit]
	}
	return rows, nil
}
