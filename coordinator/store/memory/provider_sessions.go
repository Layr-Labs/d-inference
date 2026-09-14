package memory

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// OpenProviderSession records the start of a provider connection. Idempotent
// (mirrors the postgres ON CONFLICT DO NOTHING): if a row for sessionID already
// exists — duplicate register, or open racing behind a close — it does nothing.
func (s *Store) OpenProviderSession(_ context.Context, sessionID, serial, accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.providerSessions {
		if s.providerSessions[i].SessionID == sessionID {
			return nil
		}
	}
	now := time.Now()
	s.providerSessionSeq++
	s.providerSessions = append(s.providerSessions, contracts.ProviderSession{
		ID:           s.providerSessionSeq,
		SessionID:    sessionID,
		SerialNumber: serial,
		AccountID:    accountID,
		ConnectedAt:  now,
		LastSeen:     now,
	})
	return nil
}

// TouchProviderSession updates the open session's last_seen and backfills
// serial/account/provider_key if they were unknown at open time.
func (s *Store) TouchProviderSession(_ context.Context, sessionID, serial, accountID, providerKey string, lastSeen time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.providerSessions {
		ps := &s.providerSessions[i]
		if ps.SessionID == sessionID && ps.DisconnectedAt == nil {
			ps.LastSeen = lastSeen
			if ps.SerialNumber == "" {
				ps.SerialNumber = serial
			}
			if ps.AccountID == "" {
				ps.AccountID = accountID
			}
			if ps.ProviderKey == "" {
				ps.ProviderKey = providerKey
			}
			// At most one open row per sessionID (OpenProviderSession
			// guarantees it), so stop scanning once matched.
			return nil
		}
	}
	return nil
}

// CloseProviderSession marks the session for sessionID as ended. Upsert
// semantics (mirrors postgres): closes an open row; leaves an already-closed row
// untouched; and if the row is missing (close raced ahead of open) inserts an
// already-closed row so no permanently-open session can be orphaned.
func (s *Store) CloseProviderSession(_ context.Context, sessionID, reason string, when time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.providerSessions {
		ps := &s.providerSessions[i]
		if ps.SessionID == sessionID {
			if ps.DisconnectedAt == nil {
				t := when
				ps.DisconnectedAt = &t
				ps.DisconnectReason = reason
			}
			return nil
		}
	}
	t := when
	s.providerSessionSeq++
	s.providerSessions = append(s.providerSessions, contracts.ProviderSession{
		ID:               s.providerSessionSeq,
		SessionID:        sessionID,
		ConnectedAt:      when,
		LastSeen:         when,
		DisconnectedAt:   &t,
		DisconnectReason: reason,
	})
	return nil
}

// CloseOpenProviderSessions closes any sessions still open, setting
// disconnected_at to the last heartbeat (startup reconcile).
func (s *Store) CloseOpenProviderSessions(_ context.Context, staleBefore time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for i := range s.providerSessions {
		ps := &s.providerSessions[i]
		// Only close genuinely-orphaned sessions (last heartbeat older than the
		// staleness fence); a session still touched by another live instance
		// during a blue-green deploy stays fresh and is left open.
		if ps.DisconnectedAt == nil && ps.LastSeen.Before(staleBefore) {
			t := ps.LastSeen
			ps.DisconnectedAt = &t
			ps.DisconnectReason = "coordinator_restart"
			n++
		}
	}
	return n, nil
}
