package store

import (
	"context"
	"sort"
	"time"
)

// ReconcileMachineInventory repairs missed terminal captures from durable rows,
// including after a process restart. It never changes serving/accounting state.
type MachineInventoryReconcileStore interface {
	ReconcileMachineInventory(context.Context, time.Time, int) (int, error)
}

func inventoryReconcileLimit(limit int) int {
	if limit < 1 || limit > 100 {
		return 100
	}
	return limit
}

func (s *PostgresStore) ReconcileMachineInventory(ctx context.Context, staleBefore time.Time, limit int) (int, error) {
	var count int
	err := s.pool.QueryRow(ctx, `WITH candidates AS (
	 SELECT m.session_id,GREATEST(m.last_seen,p.last_seen) AS last_seen,
	 COALESCE(p.disconnected_at,GREATEST(m.last_seen,p.last_seen)) AS closed_at,
	 CASE WHEN p.disconnected_at IS NOT NULL THEN 'provider_session' ELSE 'inventory_stale' END AS reason
	 FROM darkbloom_machine_sessions m LEFT JOIN provider_sessions p USING(session_id)
	 WHERE m.disconnected_at IS NULL AND m.last_seen < $1
	 AND (p.session_id IS NULL OR p.disconnected_at IS NOT NULL OR p.last_seen < $1)
	 ORDER BY m.last_seen,m.session_id LIMIT $2 FOR UPDATE OF m SKIP LOCKED
	), changed AS (
	 UPDATE darkbloom_machine_sessions m SET disconnected_at=c.closed_at,last_seen=c.last_seen,
	 observation=m.observation || jsonb_build_object('disconnected',true,'disconnect_reason',c.reason,'observed_at',c.last_seen)
	 FROM candidates c WHERE m.session_id=c.session_id RETURNING m.session_id,m.observation
	), history AS (
	 INSERT INTO darkbloom_machine_observations(session_id,observed_at,observation)
	 SELECT session_id,CURRENT_TIMESTAMP,observation FROM changed ON CONFLICT DO NOTHING
	) SELECT COUNT(*) FROM changed`, staleBefore, inventoryReconcileLimit(limit)).Scan(&count)
	return count, err
}

func (s *MemoryStore) ReconcileMachineInventory(ctx context.Context, staleBefore time.Time, limit int) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.machineInventory == nil {
		return 0, nil
	}
	sessions := make(map[string]ProviderSession, len(s.providerSessions))
	for _, p := range s.providerSessions {
		sessions[p.SessionID] = p
	}
	m := s.machineInventory
	var candidates []MachineObservation
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
		if count == inventoryReconcileLimit(limit) {
			break
		}
		p := sessions[o.SessionID]
		o.Disconnected = true
		o.DisconnectReason = inventoryStaleDisconnectReason
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
