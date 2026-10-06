package memory

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// CreateBillingSession stores a new billing session.
func (s *MemoryStore) CreateBillingSession(session *store.BillingSession) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.billingSessions[session.ID]; exists {
		return fmt.Errorf("billing session %q already exists", session.ID)
	}
	copy := *session
	u := s.usersByAccountID[session.AccountID]
	rejected := u != nil && u.DeletedAt != nil
	externalID := session.ExternalID
	if session.PaymentMethod != "stripe" {
		externalID = ""
	}
	if s.retainDeletedExternalObjectLocked(session.AccountID, store.ErasureTargetCheckoutSessions, externalID) {
		copy.ExternalID, copy.ReferralCode, copy.Status = "", "", "erased"
	}
	s.billingSessions[session.ID] = &copy
	if rejected {
		return store.ErrErasureConflict
	}
	return nil
}

// GetBillingSession retrieves a billing session by ID.
func (s *MemoryStore) GetBillingSession(sessionID string) (*store.BillingSession, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	session, ok := s.billingSessions[sessionID]
	if !ok {
		return nil, fmt.Errorf("billing session %q not found", sessionID)
	}
	copy := *session
	return &copy, nil
}

// CompleteBillingSession marks a session as completed.
func (s *MemoryStore) CompleteBillingSession(sessionID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	session, ok := s.billingSessions[sessionID]
	if !ok {
		return fmt.Errorf("billing session %q not found", sessionID)
	}
	if session.Status == "completed" {
		return fmt.Errorf("billing session %q already completed", sessionID)
	}
	session.Status = "completed"
	now := time.Now()
	session.CompletedAt = &now
	return nil
}
