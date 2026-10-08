package postgres

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func (s *PostgresStore) AutopilotRewardEnrollments(ctx context.Context, after string, limit int) ([]earningsfloor.Enrollment, error) {
	if limit <= 0 {
		limit = 100
	} else if limit > 200 {
		limit = 200
	}
	result := make([]earningsfloor.Enrollment, 0, limit)
	for len(result) < limit {
		// Include durable declarations whose session acquired identity after its
		// last connection died. Listing reconciles them instead of waiting for a
		// heartbeat that may never arrive. Offline and history-required rows stay.
		rows, err := s.pool.Query(ctx, `WITH RECURSIVE enrolled AS (
		 SELECT machine_id AS id FROM autopilot_reward_enrollments
		 UNION SELECT s.machine_id FROM darkbloom_machine_sessions s JOIN autopilot_reward_consents c USING(session_id)
		 WHERE c.opted_in AND c.supported
		), chain AS (
		 SELECT m.id,m.merged_into FROM darkbloom_machines m JOIN enrolled e ON e.id=m.id
		 UNION SELECT m.id,m.merged_into FROM darkbloom_machines m JOIN chain c ON c.merged_into=m.id
		) SELECT id FROM chain WHERE merged_into IS NULL AND id>$1 ORDER BY id LIMIT $2`, after, limit)
		if err != nil {
			return nil, err
		}
		var candidates []string
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
			candidates = append(candidates, id)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, err
		}
		if len(candidates) == 0 {
			break
		}
		for _, id := range candidates {
			enrollment, err := s.autopilotRewardEnrollment(ctx, id)
			if errors.Is(err, earningsfloor.ErrIdentity) || errors.Is(err, store.ErrErasureConflict) {
				continue
			}
			if err != nil {
				return nil, err
			}
			// A merge between candidate discovery and admission may change its
			// canonical ID. Leave it for that ID's page, preserving keyset order.
			if enrollment.MachineID == id {
				result = append(result, enrollment)
				if len(result) == limit {
					return result, nil
				}
			}
		}
		after = candidates[len(candidates)-1]
	}
	return result, nil
}
