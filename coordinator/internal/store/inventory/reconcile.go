package inventory

import (
	"context"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *State) ReconcileMachineInventory(ctx context.Context, staleBefore time.Time, limit int) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}

	if s == nil {
		return 0, nil
	}
	Sessions := make(map[string]store.ProviderSession, len(s.History.ProviderSessions))
	for _, p := range s.History.ProviderSessions {
		Sessions[p.SessionID] = p
	}
	m := s
	var candidates []store.MachineObservation
	for _, o := range m.Sessions {
		p, exists := Sessions[o.SessionID]
		if o.Disconnected || !o.At.Before(staleBefore) || exists && p.DisconnectedAt == nil && !p.LastSeen.Before(staleBefore) {
			continue
		}
		candidates = append(candidates, o)
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].At.Equal(candidates[j].At) {
			return candidates[i].SessionID < candidates[j].SessionID
		}
		return candidates[i].At.Before(candidates[j].At)
	})
	count := 0
	for _, o := range candidates {
		if count == shared.InventoryReconcileLimit(limit) {
			break
		}
		p := Sessions[o.SessionID]
		o.Disconnected = true
		o.DisconnectReason = shared.InventoryStaleDisconnectReason
		if p.DisconnectedAt != nil {
			o.DisconnectReason = "provider_session"
		}
		if p.LastSeen.After(o.At) {
			o.At = p.LastSeen
		}
		m.Sessions[o.SessionID] = o
		count++
	}
	return count, nil
}
