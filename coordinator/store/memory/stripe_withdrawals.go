package memory

import (
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// createStripeWithdrawalLocked inserts the row and its secondary indexes.
// Caller must hold s.mu and must have validated w.
func (s *MemoryStore) createStripeWithdrawalLocked(w *store.StripeWithdrawal) {
	cp := *w
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}
	if cp.UpdatedAt.IsZero() {
		cp.UpdatedAt = cp.CreatedAt
	}
	s.stripeWithdrawalsByID[cp.ID] = &cp
	if cp.TransferID != "" {
		s.stripeWithdrawalsByTransferID[cp.TransferID] = cp.ID
	}
	if cp.PayoutID != "" {
		s.stripeWithdrawalsByPayoutID[cp.PayoutID] = cp.ID
	}
	s.stripeWithdrawalsByAccount[cp.AccountID] = append(s.stripeWithdrawalsByAccount[cp.AccountID], cp.ID)
}

// CreateStripeWithdrawalWithDebit atomically debits both balance columns and
// inserts the withdrawal row under one lock — either both happen or neither.
func (s *MemoryStore) CreateStripeWithdrawalWithDebit(w *store.StripeWithdrawal, entryType store.LedgerEntryType, reference string) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	amount := w.AmountMicroUSD
	if amount <= 0 {
		return errors.New("stripe withdrawal amount must be positive")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.stripeWithdrawalsByID[w.ID]; exists {
		return fmt.Errorf("stripe withdrawal %q already exists", w.ID)
	}
	if s.withdrawable[w.AccountID] < amount || s.balances[w.AccountID] < amount {
		return fmt.Errorf("insufficient withdrawable balance: have %d, need %d micro-USD: %w",
			s.withdrawable[w.AccountID], amount, store.ErrInsufficientBalance)
	}
	s.balances[w.AccountID] -= amount
	s.withdrawable[w.AccountID] -= amount
	s.ledgerSeq++
	s.history.LedgerEntries = append(s.history.LedgerEntries, store.LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      w.AccountID,
		Type:           entryType,
		AmountMicroUSD: -amount,
		BalanceAfter:   s.balances[w.AccountID],
		Reference:      reference,
		CreatedAt:      time.Now(),
	})
	s.createStripeWithdrawalLocked(w)
	return nil
}

func (s *MemoryStore) GetStripeWithdrawal(id string) (*store.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal %q not found", id)
	}
	cp := *w
	return &cp, nil
}

func (s *MemoryStore) GetStripeWithdrawalByPayoutID(payoutID string) (*store.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.stripeWithdrawalsByPayoutID[payoutID]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal with payout %q: %w", payoutID, store.ErrNotFound)
	}
	w := s.stripeWithdrawalsByID[id]
	cp := *w
	return &cp, nil
}

func (s *MemoryStore) GetStripeWithdrawalByTransferID(transferID string) (*store.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.stripeWithdrawalsByTransferID[transferID]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal with transfer %q: %w", transferID, store.ErrNotFound)
	}
	w := s.stripeWithdrawalsByID[id]
	cp := *w
	return &cp, nil
}

func (s *MemoryStore) UpdateStripeWithdrawal(w *store.StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	existing, ok := s.stripeWithdrawalsByID[w.ID]
	if !ok {
		return fmt.Errorf("stripe withdrawal %q not found", w.ID)
	}
	// Re-index transfer/payout IDs if they changed.
	if existing.TransferID != w.TransferID {
		if existing.TransferID != "" {
			delete(s.stripeWithdrawalsByTransferID, existing.TransferID)
		}
		if w.TransferID != "" {
			s.stripeWithdrawalsByTransferID[w.TransferID] = w.ID
		}
	}
	if existing.PayoutID != w.PayoutID {
		if existing.PayoutID != "" {
			delete(s.stripeWithdrawalsByPayoutID, existing.PayoutID)
		}
		if w.PayoutID != "" {
			s.stripeWithdrawalsByPayoutID[w.PayoutID] = w.ID
		}
	}
	cp := *w
	cp.UpdatedAt = time.Now()
	s.stripeWithdrawalsByID[w.ID] = &cp
	return nil
}

func (s *MemoryStore) ListStripeWithdrawals(accountID string, limit int) ([]store.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	ids := s.stripeWithdrawalsByAccount[accountID]
	if len(ids) == 0 {
		return []store.StripeWithdrawal{}, nil
	}
	out := make([]store.StripeWithdrawal, 0, len(ids))
	for i := len(ids) - 1; i >= 0; i-- {
		w, ok := s.stripeWithdrawalsByID[ids[i]]
		if !ok {
			continue
		}
		out = append(out, *w)
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	return out, nil
}

// MarkStripeWithdrawalPaid atomically flips a non-terminal, non-refunded
// withdrawal to "paid" under the store lock (see interface doc).
func (s *MemoryStore) MarkStripeWithdrawalPaid(id, expectedPayoutID, sweepPayoutID string) (bool, error) {
	if id == "" {
		return false, errors.New("stripe withdrawal id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return false, fmt.Errorf("stripe withdrawal %q: %w", id, store.ErrNotFound)
	}
	if w.Refunded || (w.Status != "pending" && w.Status != "transferred") {
		return false, nil
	}
	if w.PayoutID != expectedPayoutID {
		return false, nil // payout detached/replaced concurrently — stale event
	}
	w.Status = "paid"
	if sweepPayoutID != "" {
		w.SweepPayoutID = sweepPayoutID
	}
	w.UpdatedAt = time.Now()
	return true, nil
}

// ReopenStripeWithdrawalAfterPayoutFailure atomically reopens a bounced
// withdrawal for sweep retry under the store lock (see interface doc).
func (s *MemoryStore) ReopenStripeWithdrawalAfterPayoutFailure(id, failureReason string, feeRefunded bool) (bool, error) {
	if id == "" {
		return false, errors.New("stripe withdrawal id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return false, fmt.Errorf("stripe withdrawal %q: %w", id, store.ErrNotFound)
	}
	if w.Refunded || w.Status == "failed" {
		return false, nil // a concurrent reversal terminalized it — never reopen
	}
	if w.PayoutID != "" {
		delete(s.stripeWithdrawalsByPayoutID, w.PayoutID)
	}
	w.Status = "transferred"
	w.PayoutID = ""
	w.FailureReason = failureReason
	w.FeeRefunded = w.FeeRefunded || feeRefunded
	w.UpdatedAt = time.Now()
	return true, nil
}

// ListStripeWithdrawalsBySweepPayoutID returns the rows stamped by the given
// automatic sweep payout, oldest first.
func (s *MemoryStore) ListStripeWithdrawalsBySweepPayoutID(sweepPayoutID string) ([]store.StripeWithdrawal, error) {
	if sweepPayoutID == "" {
		return []store.StripeWithdrawal{}, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []store.StripeWithdrawal{}
	for _, w := range s.stripeWithdrawalsByID {
		if w.SweepPayoutID == sweepPayoutID {
			out = append(out, *w)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out, nil
}

// ListStripeWithdrawalsByStatus returns up to limit withdrawals in the given
// status created before olderThan, oldest first. Limits <= 0 or above the cap
// are clamped to MaxStripeWithdrawalsByStatusLimit.
func (s *MemoryStore) ListStripeWithdrawalsByStatus(status string, olderThan time.Time, limit int) ([]store.StripeWithdrawal, error) {
	if limit <= 0 || limit > store.MaxStripeWithdrawalsByStatusLimit {
		limit = store.MaxStripeWithdrawalsByStatusLimit
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []store.StripeWithdrawal{}
	for _, w := range s.stripeWithdrawalsByID {
		if w.Status == status && w.CreatedAt.Before(olderThan) {
			out = append(out, *w)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// ListStripeWithdrawalsForStripeAccount returns withdrawals destined for the
// given connected account in the given status, oldest first. Capped at
// MaxStripeWithdrawalsByStatusLimit (see the postgres impl for rationale).
func (s *MemoryStore) ListStripeWithdrawalsForStripeAccount(stripeAccountID, status string) ([]store.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []store.StripeWithdrawal{}
	for _, w := range s.stripeWithdrawalsByID {
		if w.StripeAccountID == stripeAccountID && w.Status == status {
			out = append(out, *w)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	if len(out) > store.MaxStripeWithdrawalsByStatusLimit {
		out = out[:store.MaxStripeWithdrawalsByStatusLimit]
	}
	return out, nil
}
