package memory

import (
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func stripeRejectionAllowed(w *store.StripeWithdrawal, reason string) bool {
	return reason != "" && w != nil && !w.Refunded && w.TransferID == "" && w.PayoutID == "" && w.SweepPayoutID == "" && (w.Status == "pending" || (w.Status == "failed" && strings.HasPrefix(w.FailureReason, "transfer_create_failed:")))
}

func (s *MemoryStore) RecordStripeTransferRejection(id, reason string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	w := s.stripeWithdrawalsByID[id]
	if !stripeRejectionAllowed(w, reason) {
		return store.ErrPayoutConflict
	}
	w.Status, w.FailureReason, w.UpdatedAt = "failed", store.StripeConfirmedRejectionPrefix+reason, time.Now()
	return nil
}

func (s *MemoryStore) RefundRejectedStripeWithdrawal(id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	w := s.stripeWithdrawalsByID[id]
	if w == nil {
		return false, store.ErrNotFound
	}
	if w.Refunded {
		return false, nil
	}
	if !store.StripeRefundRecoverable(w) {
		return false, store.ErrPayoutConflict
	}
	ref := "stripe_withdraw:" + id
	applied := true
	var debited int64
	for _, e := range s.history.LedgerEntries {
		if e.AccountID == w.AccountID && e.Type == store.LedgerStripePayout && e.Reference == ref {
			debited += e.AmountMicroUSD
		}
		if e.AccountID == w.AccountID && e.Type == store.LedgerRefund && e.Reference == ref {
			if e.AmountMicroUSD != w.AmountMicroUSD {
				return false, store.ErrPayoutConflict
			}
			applied = false
		}
	}
	if debited != -w.AmountMicroUSD {
		return false, store.ErrPayoutConflict
	}
	if applied {
		if s.creditLocked(w.AccountID, w.AmountMicroUSD, store.LedgerRefund, ref, time.Now()) {
			s.withdrawable[w.AccountID] += w.AmountMicroUSD
		}
	}
	w.Refunded, w.UpdatedAt = true, time.Now()
	return applied, nil
}

func (s *MemoryStore) CompleteStripeCheckout(id, externalID, accountID string, amount int64) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b := s.billingSessions[id]
	if b == nil {
		return false, store.ErrNotFound
	}
	if b.Status == "erased" || s.erasedAccounts[b.AccountID] {
		return false, store.ErrCheckoutErased
	}
	if !shared.CheckoutMatches(b, externalID, accountID, amount) {
		return false, store.ErrPayoutConflict
	}
	if b.Status == "completed" {
		return false, nil
	}
	applied := true
	for _, e := range s.history.LedgerEntries {
		if e.AccountID == accountID && e.Type == store.LedgerStripeDeposit && e.Reference == "stripe:"+externalID {
			if e.AmountMicroUSD != amount {
				return false, store.ErrPayoutConflict
			}
			applied = false
		}
	}
	if applied {
		s.creditLocked(accountID, amount, store.LedgerStripeDeposit, "stripe:"+externalID, time.Now())
	}
	now := time.Now()
	b.Status, b.CompletedAt = "completed", &now
	return applied, nil
}

func (s *MemoryStore) ListStripeRefundsToRecover(limit int) ([]store.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > store.MaxStripeWithdrawalsByStatusLimit {
		limit = store.MaxStripeWithdrawalsByStatusLimit
	}
	out := []store.StripeWithdrawal{}
	for _, w := range s.stripeWithdrawalsByID {
		if store.StripeRefundRecoverable(w) {
			out = append(out, *w)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.Before(out[j].UpdatedAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
