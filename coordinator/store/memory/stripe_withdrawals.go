package memory

import (
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/internal/payoutstate"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) CreateStripeWithdrawal(w *contracts.StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.stripeWithdrawalsByID[w.ID]; exists {
		return fmt.Errorf("stripe withdrawal %q already exists", w.ID)
	}
	s.createStripeWithdrawalLocked(w)
	return nil
}

// createStripeWithdrawalLocked inserts the row and its secondary indexes.
// Caller must hold s.mu and must have validated w.
func (s *Store) createStripeWithdrawalLocked(w *contracts.StripeWithdrawal) {
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
func (s *Store) CreateStripeWithdrawalWithDebit(w *contracts.StripeWithdrawal, entryType contracts.LedgerEntryType, reference string) error {
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
			s.withdrawable[w.AccountID], amount, contracts.ErrInsufficientBalance)
	}
	s.balances[w.AccountID] -= amount
	s.withdrawable[w.AccountID] -= amount
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, contracts.LedgerEntry{
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

func (s *Store) GetStripeWithdrawal(id string) (*contracts.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal %q not found", id)
	}
	cp := *w
	return &cp, nil
}

func (s *Store) GetStripeWithdrawalByPayoutID(payoutID string) (*contracts.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.stripeWithdrawalsByPayoutID[payoutID]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal with payout %q: %w", payoutID, contracts.ErrNotFound)
	}
	w := s.stripeWithdrawalsByID[id]
	cp := *w
	return &cp, nil
}

func (s *Store) GetStripeWithdrawalByTransferID(transferID string) (*contracts.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.stripeWithdrawalsByTransferID[transferID]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal with transfer %q: %w", transferID, contracts.ErrNotFound)
	}
	w := s.stripeWithdrawalsByID[id]
	cp := *w
	return &cp, nil
}

func (s *Store) UpdateStripeWithdrawal(w *contracts.StripeWithdrawal) error {
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

func (s *Store) ListStripeWithdrawals(accountID string, limit int) ([]contracts.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	ids := s.stripeWithdrawalsByAccount[accountID]
	if len(ids) == 0 {
		return []contracts.StripeWithdrawal{}, nil
	}
	out := make([]contracts.StripeWithdrawal, 0, len(ids))
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
func (s *Store) MarkStripeWithdrawalPaid(id, expectedPayoutID, sweepPayoutID string) (bool, error) {
	if id == "" {
		return false, errors.New("stripe withdrawal id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return false, fmt.Errorf("stripe withdrawal %q: %w", id, contracts.ErrNotFound)
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
func (s *Store) ReopenStripeWithdrawalAfterPayoutFailure(id, expectedPayoutID, failureReason string, feeRefunded bool) (bool, error) {
	if id == "" || expectedPayoutID == "" {
		return false, errors.New("stripe withdrawal id and expected payout id are required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return false, fmt.Errorf("stripe withdrawal %q: %w", id, contracts.ErrNotFound)
	}
	if w.Refunded || w.Status == "failed" || w.PayoutID != expectedPayoutID {
		return false, nil // reversal or a different payout owns the current state
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
func (s *Store) ListStripeWithdrawalsBySweepPayoutID(sweepPayoutID string) ([]contracts.StripeWithdrawal, error) {
	if sweepPayoutID == "" {
		return []contracts.StripeWithdrawal{}, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []contracts.StripeWithdrawal{}
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
func (s *Store) ListStripeWithdrawalsByStatus(status string, olderThan time.Time, limit int) ([]contracts.StripeWithdrawal, error) {
	if limit <= 0 || limit > contracts.MaxStripeWithdrawalsByStatusLimit {
		limit = contracts.MaxStripeWithdrawalsByStatusLimit
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []contracts.StripeWithdrawal{}
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
func (s *Store) ListStripeWithdrawalsForStripeAccount(stripeAccountID, status string) ([]contracts.StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []contracts.StripeWithdrawal{}
	for _, w := range s.stripeWithdrawalsByID {
		if w.StripeAccountID == stripeAccountID && w.Status == status {
			out = append(out, *w)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	if len(out) > contracts.MaxStripeWithdrawalsByStatusLimit {
		out = out[:contracts.MaxStripeWithdrawalsByStatusLimit]
	}
	return out, nil
}

func (s *Store) ReopenStripeWithdrawalAfterSweepFailure(id, expectedSweepPayoutID, failureReason string) (bool, error) {
	if id == "" || expectedSweepPayoutID == "" {
		return false, errors.New("stripe withdrawal and sweep payout ids are required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok || w.Status != "paid" || w.Refunded || w.SweepPayoutID != expectedSweepPayoutID {
		return false, nil
	}
	w.Status = "transferred"
	w.SweepPayoutID = ""
	w.FailureReason = failureReason
	w.UpdatedAt = time.Now()
	return true, nil
}

func (s *Store) CompareAndSwapStripeWithdrawal(previous, next *contracts.StripeWithdrawal) (bool, error) {
	if err := payoutstate.ValidateStripeUpdate(previous, next); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.stripeWithdrawalsByID[next.ID]
	if current == nil {
		return false, nil
	}
	currentState, nextState := payoutstate.StripeProgressOf(current), payoutstate.StripeProgressOf(next)
	if currentState == nextState {
		return true, nil
	}
	if currentState != payoutstate.StripeProgressOf(previous) {
		return false, nil
	}
	if current.TransferID != next.TransferID {
		delete(s.stripeWithdrawalsByTransferID, current.TransferID)
		if next.TransferID != "" {
			s.stripeWithdrawalsByTransferID[next.TransferID] = next.ID
		}
	}
	if current.PayoutID != next.PayoutID {
		delete(s.stripeWithdrawalsByPayoutID, current.PayoutID)
		if next.PayoutID != "" {
			s.stripeWithdrawalsByPayoutID[next.PayoutID] = next.ID
		}
	}
	current.TransferID = next.TransferID
	current.PayoutID = next.PayoutID
	current.SweepPayoutID = next.SweepPayoutID
	current.Status = next.Status
	current.FailureReason = next.FailureReason
	current.Refunded = next.Refunded
	current.FeeRefunded = next.FeeRefunded
	current.UpdatedAt = time.Now()
	return true, nil
}
