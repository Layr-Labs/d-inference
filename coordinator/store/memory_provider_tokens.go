package store

import (
	"errors"
)

// --- Provider Tokens ---

func (s *MemoryStore) CreateProviderToken(pt *ProviderToken) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.providerTokens[pt.TokenHash]; exists {
		return errors.New("provider token already exists")
	}
	copy := *pt
	s.providerTokens[pt.TokenHash] = &copy
	return nil
}

func (s *MemoryStore) GetProviderToken(token string) (*ProviderToken, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	h := HashKey(token)
	pt, ok := s.providerTokens[h]
	if !ok {
		return nil, errors.New("provider token not found")
	}
	if !pt.Active {
		return nil, errors.New("provider token is revoked")
	}
	copy := *pt
	return &copy, nil
}

func (s *MemoryStore) RevokeProviderToken(token string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	h := HashKey(token)
	pt, ok := s.providerTokens[h]
	if !ok {
		return errors.New("provider token not found")
	}
	pt.Active = false
	return nil
}
