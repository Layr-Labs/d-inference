package store

import (
	"context"
	"time"
)

func (s *MemoryStore) RecoverLiveAppAttestMachineSession(ctx context.Context, sessionID, account, key string, now time.Time) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if sessionID == "" || account == "" || key == "" || now.IsZero() {
		return false, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.machineInventory
	if m == nil {
		return false, nil
	}
	o, exists := m.sessions[sessionID]
	if !exists || o.AccountID != account || !o.Disconnected || o.Source != "historical_registration" || o.DisconnectReason != "observed_disconnect" {
		return false, nil
	}
	k, exists := s.appAttestShadowKeys[key]
	if !exists || k.AccountID != account || s.appAttestRevocations[key] {
		return false, nil
	}
	if existing := m.aliases[appAttestMachineAlias(account, key)]; existing != "" && existing != m.sessionMachines[sessionID] {
		return false, nil
	}
	for _, p := range s.providerSessions {
		if p.SessionID != sessionID || p.AccountID != account || p.DisconnectedAt != nil ||
			!p.LastSeen.After(o.At) || p.LastSeen.Before(now.Add(-2*time.Minute)) {
			continue
		}
		o.Disconnected, o.DisconnectReason = false, ""
		o.Source, o.At = "live_assertion_recovery", now
		m.sessions[sessionID] = o
		return true, nil
	}
	return false, nil
}
