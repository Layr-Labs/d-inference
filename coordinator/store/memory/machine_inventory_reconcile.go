package memory

import (
	"context"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

func (s *MemoryStore) ReconcileMachineInventory(ctx context.Context, staleBefore time.Time, limit int) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.machineInventory == nil {
		return 0, nil
	}
	sessions := make(map[string]store.ProviderSession, len(s.providerSessions))
	for _, p := range s.providerSessions {
		sessions[p.SessionID] = p
	}
	m := s.machineInventory
	var candidates []store.MachineObservation
	for _, o := range m.sessions {
		p, exists := sessions[o.SessionID]
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
		p := sessions[o.SessionID]
		o.Disconnected = true
		o.DisconnectReason = shared.InventoryStaleDisconnectReason
		if p.DisconnectedAt != nil {
			o.DisconnectReason = "provider_session"
		}
		if p.LastSeen.After(o.At) {
			o.At = p.LastSeen
		}
		m.sessions[o.SessionID] = o
		count++
	}
	return count, nil
}
