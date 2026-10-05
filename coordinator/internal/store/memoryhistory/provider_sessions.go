package memoryhistory

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// OpenProviderSession records the start of a provider connection. Idempotent
// (mirrors the postgres ON CONFLICT DO NOTHING): if a row for sessionID already
// exists — duplicate register, or open racing behind a close — it does nothing.
func (s *State) OpenProviderSession(_ context.Context, sessionID, serial, accountID string) error {

	for i := range s.ProviderSessions {
		if s.ProviderSessions[i].SessionID == sessionID {
			return nil
		}
	}
	now := time.Now()
	s.ProviderSessionSeq++
	s.ProviderSessions = append(s.ProviderSessions, store.ProviderSession{
		ID:           s.ProviderSessionSeq,
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
func (s *State) TouchProviderSession(_ context.Context, sessionID, serial, accountID, providerKey string, lastSeen time.Time) error {

	for i := range s.ProviderSessions {
		ps := &s.ProviderSessions[i]
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
func (s *State) CloseProviderSession(_ context.Context, sessionID, reason string, when time.Time) error {

	for i := range s.ProviderSessions {
		ps := &s.ProviderSessions[i]
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
	s.ProviderSessionSeq++
	s.ProviderSessions = append(s.ProviderSessions, store.ProviderSession{
		ID:               s.ProviderSessionSeq,
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
func (s *State) CloseOpenProviderSessions(_ context.Context, staleBefore time.Time) (int, error) {

	n := 0
	for i := range s.ProviderSessions {
		ps := &s.ProviderSessions[i]
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
