package store

import (
	"errors"
	"fmt"
	"time"
)

// --- Stripe Withdrawals ---

func (s *MemoryStore) CreateStripeWithdrawal(w *StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.stripeWithdrawalsByID[w.ID]; exists {
		return fmt.Errorf("stripe withdrawal %q already exists", w.ID)
	}
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
	return nil
}

func (s *MemoryStore) GetStripeWithdrawal(id string) (*StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	w, ok := s.stripeWithdrawalsByID[id]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal %q not found", id)
	}
	cp := *w
	return &cp, nil
}

func (s *MemoryStore) GetStripeWithdrawalByPayoutID(payoutID string) (*StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.stripeWithdrawalsByPayoutID[payoutID]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal with payout %q not found", payoutID)
	}
	w := s.stripeWithdrawalsByID[id]
	cp := *w
	return &cp, nil
}

func (s *MemoryStore) GetStripeWithdrawalByTransferID(transferID string) (*StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.stripeWithdrawalsByTransferID[transferID]
	if !ok {
		return nil, fmt.Errorf("stripe withdrawal with transfer %q not found", transferID)
	}
	w := s.stripeWithdrawalsByID[id]
	cp := *w
	return &cp, nil
}

func (s *MemoryStore) UpdateStripeWithdrawal(w *StripeWithdrawal) error {
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

func (s *MemoryStore) ListStripeWithdrawals(accountID string, limit int) ([]StripeWithdrawal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	ids := s.stripeWithdrawalsByAccount[accountID]
	if len(ids) == 0 {
		return []StripeWithdrawal{}, nil
	}
	out := make([]StripeWithdrawal, 0, len(ids))
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
