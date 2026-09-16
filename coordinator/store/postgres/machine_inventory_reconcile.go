package postgres

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/internal/inventoryrecord"
)

func (s *Store) ReconcileMachineInventory(ctx context.Context, staleBefore time.Time, limit int) (int, error) {
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
	) SELECT COUNT(*) FROM changed`, staleBefore, inventoryrecord.ReconcileLimit(limit)).Scan(&count)
	return count, err
}
