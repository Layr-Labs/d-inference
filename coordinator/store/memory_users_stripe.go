package store

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// --- Users (Privy) ---

// CreateUser creates a new user record linked to a Privy identity.
func (s *MemoryStore) CreateUser(user *User) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.usersByPrivyID[user.PrivyUserID]; exists {
		return fmt.Errorf("user with Privy ID %q already exists", user.PrivyUserID)
	}
	if _, exists := s.usersByAccountID[user.AccountID]; exists {
		return fmt.Errorf("user with account ID %q already exists", user.AccountID)
	}

	copy := *user
	copy.CreatedAt = time.Now()
	s.usersByPrivyID[user.PrivyUserID] = &copy
	s.usersByAccountID[user.AccountID] = &copy
	return nil
}

// GetUserByPrivyID returns the user for a Privy DID.
func (s *MemoryStore) GetUserByPrivyID(privyUserID string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByPrivyID[privyUserID]
	if !ok {
		return nil, fmt.Errorf("user with Privy ID %q not found", privyUserID)
	}
	copy := *u
	return &copy, nil
}

// GetUserByAccountID returns the user for an internal account ID.
func (s *MemoryStore) GetUserByAccountID(accountID string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByAccountID[accountID]
	if !ok {
		return nil, fmt.Errorf("user with account ID %q not found", accountID)
	}
	copy := *u
	return &copy, nil
}

// SetUserStripeAccount upserts the Stripe Connect fields on a user record.
func (s *MemoryStore) SetUserStripeAccount(accountID, stripeAccountID, status, destinationType, destinationLast4 string, instantEligible bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	u, ok := s.usersByAccountID[accountID]
	if !ok {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}

	// Maintain the by-stripe-account index. A user may switch accounts (e.g.
	// after a manual reset) so we drop the old mapping if it was different.
	if u.StripeAccountID != "" && u.StripeAccountID != stripeAccountID {
		delete(s.usersByStripeAccountID, u.StripeAccountID)
	}

	u.StripeAccountID = stripeAccountID
	u.StripeAccountStatus = status
	u.StripeDestinationType = destinationType
	u.StripeDestinationLast4 = destinationLast4
	u.StripeInstantEligible = instantEligible

	if stripeAccountID != "" {
		s.usersByStripeAccountID[stripeAccountID] = u
	}
	return nil
}

// GetUserByStripeAccount finds a user by their Stripe connected account ID.
func (s *MemoryStore) GetUserByStripeAccount(stripeAccountID string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByStripeAccountID[stripeAccountID]
	if !ok {
		return nil, fmt.Errorf("user with Stripe account %q not found", stripeAccountID)
	}
	copy := *u
	return &copy, nil
}

// GetUserByEmail returns the user for an email address.
func (s *MemoryStore) GetUserByEmail(email string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	lower := strings.ToLower(email)
	for _, u := range s.usersByAccountID {
		if strings.ToLower(u.Email) == lower {
			copy := *u
			return &copy, nil
		}
	}
	return nil, fmt.Errorf("user with email %q not found", email)
}

// SetUserRole sets the account role on a user record.
func (s *MemoryStore) SetUserRole(accountID, role string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.usersByAccountID[accountID]
	if !ok {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	u.Role = role
	return nil
}

// SetUserPlatformFeePercent sets (or clears, when nil) the per-account
// platform fee override. A fresh pointer is allocated so stored state is never
// aliased by the caller.
func (s *MemoryStore) SetUserPlatformFeePercent(accountID string, feePercent *int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.usersByAccountID[accountID]
	if !ok {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	if feePercent == nil {
		u.PlatformFeePercent = nil
	} else {
		v := *feePercent
		u.PlatformFeePercent = &v
	}
	return nil
}

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
