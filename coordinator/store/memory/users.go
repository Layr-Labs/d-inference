package memory

import (
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// CreateUser creates a new user record linked to a Privy identity.
func (s *MemoryStore) CreateUser(user *store.User) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// A soft-deleted user does not hold its Privy ID, as with the partial
	// unique index in Postgres.
	if existing, exists := s.usersByPrivyID[user.PrivyUserID]; exists && existing.DeletedAt == nil {
		return fmt.Errorf("user with Privy ID %q already exists", user.PrivyUserID)
	}
	if _, exists := s.usersByAccountID[user.AccountID]; exists {
		return fmt.Errorf("user with account ID %q already exists", user.AccountID)
	}

	copy := *user
	copy.CreatedAt = s.now()
	s.usersByPrivyID[user.PrivyUserID] = &copy
	s.usersByAccountID[user.AccountID] = &copy
	return nil
}

// GetUserByPrivyID returns the user for a Privy DID.
func (s *MemoryStore) GetUserByPrivyID(privyUserID string) (*store.User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByPrivyID[privyUserID]
	if !ok || u.DeletedAt != nil {
		return nil, fmt.Errorf("user with Privy ID %q %w", privyUserID, store.ErrNotFound)
	}
	copy := *u
	return &copy, nil
}

// GetUserByAccountID returns the user for an internal account ID.
func (s *MemoryStore) GetUserByAccountID(accountID string) (*store.User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByAccountID[accountID]
	if !ok || u.DeletedAt != nil {
		return nil, fmt.Errorf("user with account ID %q %w", accountID, store.ErrNotFound)
	}
	copy := *u
	return &copy, nil
}

// SetUserStripeAccount upserts the Stripe Connect fields on a user record.
// stripeAccountCountry is the ISO country the Express account is locked to.
// Pass an empty string to leave the existing country value unchanged.
func (s *MemoryStore) SetUserStripeAccount(accountID, stripeAccountID, status, stripeAccountCountry, destinationType, destinationLast4 string, instantEligible bool) error {
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
	switch {
	case stripeAccountCountry != "":
		u.StripeAccountCountry = stripeAccountCountry
	case stripeAccountID == "":
		// Unlinking: an empty country normally means "keep existing" (Stripe
		// webhook partial updates), but with no account there is no country —
		// keeping a stale one would leak into the next onboarding attempt.
		u.StripeAccountCountry = ""
	}
	u.StripeDestinationType = destinationType
	u.StripeDestinationLast4 = destinationLast4
	u.StripeInstantEligible = instantEligible

	if stripeAccountID != "" {
		s.usersByStripeAccountID[stripeAccountID] = u
	}
	return nil
}

// GetUserByStripeAccount finds a user by their Stripe connected account ID.
func (s *MemoryStore) GetUserByStripeAccount(stripeAccountID string) (*store.User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByStripeAccountID[stripeAccountID]
	if !ok || u.DeletedAt != nil {
		return nil, fmt.Errorf("user with Stripe account %q not found", stripeAccountID)
	}
	copy := *u
	return &copy, nil
}

// GetUserByEmail returns the user for an email address.
func (s *MemoryStore) GetUserByEmail(email string) (*store.User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	lower := strings.ToLower(email)
	for _, u := range s.usersByAccountID {
		if strings.ToLower(u.Email) == lower && u.DeletedAt == nil {
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
