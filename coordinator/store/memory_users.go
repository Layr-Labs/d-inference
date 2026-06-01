package store

import (
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
