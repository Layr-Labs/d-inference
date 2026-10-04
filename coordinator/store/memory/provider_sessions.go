package memory

import (
	"context"
	"time"
)

func (s *MemoryStore) OpenProviderSession(ctx context.Context, sessionID, serial, accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.history.OpenProviderSession(ctx, sessionID, serial, accountID)
}
func (s *MemoryStore) TouchProviderSession(ctx context.Context, sessionID, serial, accountID, providerKey string, lastSeen time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.history.TouchProviderSession(ctx, sessionID, serial, accountID, providerKey, lastSeen)
}
func (s *MemoryStore) CloseProviderSession(ctx context.Context, sessionID, reason string, when time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.history.CloseProviderSession(ctx, sessionID, reason, when)
}
func (s *MemoryStore) CloseOpenProviderSessions(ctx context.Context, staleBefore time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.history.CloseOpenProviderSessions(ctx, staleBefore)
}
