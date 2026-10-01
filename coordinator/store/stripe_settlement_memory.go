package store

import (
	"sort"
	"time"
)

func (s *MemoryStore) RecordStripeTransferRejection(id, reason string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	w := s.stripeWithdrawalsByID[id]
	if !stripeRejectionAllowed(w, reason) {
		return ErrPayoutConflict
	}
	w.Status, w.FailureReason, w.UpdatedAt = "failed", StripeConfirmedRejectionPrefix+reason, time.Now()
	return nil
}

func (s *MemoryStore) RefundRejectedStripeWithdrawal(id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	w := s.stripeWithdrawalsByID[id]
	if w == nil {
		return false, ErrNotFound
	}
	if w.Refunded {
		return false, nil
	}
	if !StripeRefundRecoverable(w) {
		return false, ErrPayoutConflict
	}
	ref := "stripe_withdraw:" + id
	applied := true
	var debited int64
	for _, e := range s.ledgerEntries {
		if e.AccountID == w.AccountID && e.Type == LedgerStripePayout && e.Reference == ref {
			debited += e.AmountMicroUSD
		}
		if e.AccountID == w.AccountID && e.Type == LedgerRefund && e.Reference == ref {
			if e.AmountMicroUSD != w.AmountMicroUSD {
				return false, ErrPayoutConflict
			}
			applied = false
		}
	}
	if debited != -w.AmountMicroUSD {
		return false, ErrPayoutConflict
	}
	if applied {
		s.creditLocked(w.AccountID, w.AmountMicroUSD, LedgerRefund, ref, time.Now())
		s.withdrawable[w.AccountID] += w.AmountMicroUSD
	}
	w.Refunded, w.UpdatedAt = true, time.Now()
	return applied, nil
}

func (s *MemoryStore) CompleteStripeCheckout(id, externalID, accountID string, amount int64) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.billingSessions[id]
	if b == nil {
		return false, ErrNotFound
	}
	if !checkoutMatches(b, externalID, accountID, amount) {
		return false, ErrPayoutConflict
	}
	if b.Status == "completed" {
		return false, nil
	}
	applied := true
	for _, e := range s.ledgerEntries {
		if e.AccountID == accountID && e.Type == LedgerStripeDeposit && e.Reference == "stripe:"+externalID {
			if e.AmountMicroUSD != amount {
				return false, ErrPayoutConflict
			}
			applied = false
		}
	}
	if applied {
		s.creditLocked(accountID, amount, LedgerStripeDeposit, "stripe:"+externalID, time.Now())
	}
	now := time.Now()
	b.Status, b.CompletedAt = "completed", &now
	return applied, nil
}

func (s *MemoryStore) ListStripeRefundsToRecover(limit int) ([]StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > MaxStripeWithdrawalsByStatusLimit {
		limit = MaxStripeWithdrawalsByStatusLimit
	}
	out := []StripeWithdrawal{}
	for _, w := range s.stripeWithdrawalsByID {
		if StripeRefundRecoverable(w) {
			out = append(out, *w)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.Before(out[j].UpdatedAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
