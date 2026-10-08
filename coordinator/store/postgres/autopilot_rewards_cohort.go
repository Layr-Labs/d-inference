package postgres

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/jackc/pgx/v5"
)

// The inventory and privacy barriers held by the enclosing reward transaction
// keep canonical identity and peer account erasure stable during the snapshot.
func autopilotRewardBaseline(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine, anchor time.Time) (int64, string, string, error) {
	start := anchor.Add(-floorpolicy.BaselineDuration)
	if !machine.firstSeen.After(start) {
		total, err := sumAutopilotInference(ctx, tx, machine, start, anchor)
		if err != nil {
			return 0, "", "", err
		}
		return total, earningsfloor.TrackedBaseline, "tracked_inference_history", nil
	}
	key, known, err := autopilotRewardTargetCohortKey(ctx, tx, machine, anchor)
	if err != nil {
		return 0, "", "", err
	}
	if !known {
		return 0, "", "", earningsfloor.ErrHistory
	}
	peers, err := autopilotRewardCohortEarnings(ctx, tx, machine.id, key, start, anchor)
	if err != nil {
		return 0, "", "", err
	}
	total, evidence, err := floorpolicy.CohortBaselineValue(key, anchor, peers)
	if err != nil {
		return 0, "", "", err
	}
	return total, earningsfloor.CohortBaseline, evidence, nil
}

// Receive-time hardware belongs to the original declaration, independently of
// the later verified inventory association. Never substitute a later receipt.
func autopilotRewardTargetCohortKey(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine, anchor time.Time) (floorpolicy.CohortKey, bool, error) {
	rows, err := tx.Query(ctx, `SELECT chip,memory_gb FROM autopilot_reward_consents
	 WHERE machine_id=ANY($1::text[]) AND supported AND opted_in AND at=$2`, machine.ancestors, anchor)
	if err != nil {
		return floorpolicy.CohortKey{}, false, err
	}
	defer rows.Close()
	var key floorpolicy.CohortKey
	known := false
	for rows.Next() {
		var chip string
		var memoryGB float64
		if err := rows.Scan(&chip, &memoryGB); err != nil {
			return floorpolicy.CohortKey{}, false, err
		}
		if chip == "" && memoryGB == 0 {
			continue
		}
		candidate, valid := floorpolicy.ParseCohortKey(chip, memoryGB)
		if !valid || known && candidate != key {
			return floorpolicy.CohortKey{}, false, nil
		}
		key, known = candidate, true
	}
	if err := rows.Err(); err != nil {
		return floorpolicy.CohortKey{}, false, err
	}
	rows.Close()
	if known {
		return key, true, nil
	}
	// Legacy declarations contain no hardware snapshot. Their historical
	// inventory remains the only evidence; future observations fail closed.
	return autopilotRewardCohortKey(ctx, tx, machine, anchor)
}

func autopilotRewardCohortKey(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine, anchor time.Time) (floorpolicy.CohortKey, bool, error) {
	rows, err := tx.Query(ctx, `SELECT historical.observation FROM darkbloom_machine_sessions s
	 LEFT JOIN LATERAL (SELECT o.observation FROM darkbloom_machine_observations o
	  WHERE o.session_id=s.session_id AND o.observed_at<=$2 ORDER BY o.observed_at DESC LIMIT 1) historical ON TRUE
	 WHERE s.machine_id=ANY($1::text[]) AND s.first_seen<=$2`, machine.ancestors, anchor)
	if err != nil {
		return floorpolicy.CohortKey{}, false, err
	}
	defer rows.Close()
	var key floorpolicy.CohortKey
	known := false
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return floorpolicy.CohortKey{}, false, err
		}
		var observation store.MachineObservation
		if len(raw) == 0 {
			return floorpolicy.CohortKey{}, false, nil
		}
		if err := json.Unmarshal(raw, &observation); err != nil {
			return floorpolicy.CohortKey{}, false, err
		}
		candidate, valid := floorpolicy.ParseCohortKey(observation.Chip, observation.MemoryGB)
		if !valid || known && candidate != key {
			return floorpolicy.CohortKey{}, false, nil
		}
		key, known = candidate, true
	}
	return key, known, rows.Err()
}
