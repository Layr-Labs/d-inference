package memory

import (
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// CreateUser creates a new user record linked to a Privy identity.
func (s *Store) CreateUser(user *contracts.User) error {
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
func (s *Store) GetUserByPrivyID(privyUserID string) (*contracts.User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByPrivyID[privyUserID]
	if !ok {
		return nil, fmt.Errorf("user with Privy ID %q %w", privyUserID, contracts.ErrNotFound)
	}
	copy := *u
	return &copy, nil
}

// GetUserByAccountID returns the user for an internal account ID.
func (s *Store) GetUserByAccountID(accountID string) (*contracts.User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	u, ok := s.usersByAccountID[accountID]
	if !ok {
		return nil, fmt.Errorf("user with account ID %q %w", accountID, contracts.ErrNotFound)
	}
	copy := *u
	return &copy, nil
}

// SetUserStripeAccount upserts the Stripe Connect fields on a user record.
// stripeAccountCountry is the ISO country the Express account is locked to.
// Pass an empty string to leave the existing country value unchanged.
func (s *Store) SetUserStripeAccount(accountID, stripeAccountID, status, stripeAccountCountry, destinationType, destinationLast4 string, instantEligible bool) error {
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
func (s *Store) GetUserByStripeAccount(stripeAccountID string) (*contracts.User, error) {
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
func (s *Store) GetUserByEmail(email string) (*contracts.User, error) {
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
func (s *Store) SetUserRole(accountID, role string) error {
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
func (s *Store) SetUserPlatformFeePercent(accountID string, feePercent *int64) error {
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
