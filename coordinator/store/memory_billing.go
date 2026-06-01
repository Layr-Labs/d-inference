package store

import (
	"fmt"
	"time"
)

// --- Billing Sessions ---

// CreateBillingSession stores a new billing session.
func (s *MemoryStore) CreateBillingSession(session *BillingSession) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.billingSessions[session.ID]; exists {
		return fmt.Errorf("billing session %q already exists", session.ID)
	}
	copy := *session
	s.billingSessions[session.ID] = &copy
	return nil
}

// GetBillingSession retrieves a billing session by ID.
func (s *MemoryStore) GetBillingSession(sessionID string) (*BillingSession, error) {
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

// IsExternalIDProcessed returns true if a completed billing session with this external ID exists.
func (s *MemoryStore) IsExternalIDProcessed(externalID string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for _, session := range s.billingSessions {
		if session.ExternalID == externalID && session.Status == "completed" {
			return true
		}
	}
	return false
}

// --- Custom Pricing ---

func (s *MemoryStore) SetModelPrice(accountID, model string, inputPrice, outputPrice int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := accountID + ":" + model
	s.modelPrices[key] = ModelPrice{
		AccountID:   accountID,
		Model:       model,
		InputPrice:  inputPrice,
		OutputPrice: outputPrice,
	}
	return nil
}

func (s *MemoryStore) GetModelPrice(accountID, model string) (int64, int64, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	mp, ok := s.modelPrices[accountID+":"+model]
	if !ok {
		return 0, 0, false
	}
	return mp.InputPrice, mp.OutputPrice, true
}

func (s *MemoryStore) ListModelPrices(accountID string) []ModelPrice {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var prices []ModelPrice
	for _, mp := range s.modelPrices {
		if mp.AccountID == accountID {
			prices = append(prices, mp)
		}
	}
	return prices
}

func (s *MemoryStore) DeleteModelPrice(accountID, model string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := accountID + ":" + model
	if _, ok := s.modelPrices[key]; !ok {
		return fmt.Errorf("no custom price for model %q", model)
	}
	delete(s.modelPrices, key)
	return nil
}
