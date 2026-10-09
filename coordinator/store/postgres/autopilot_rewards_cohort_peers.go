package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// These two set-based reads keep query count independent of fleet size while
// the enclosing transaction holds the inventory barrier. Hardware parsing is
// shared with memory; SQL only establishes canonical ancestry and ownership.
func autopilotRewardCohortEarnings(ctx context.Context, tx pgx.Tx, excluded string, key floorpolicy.CohortKey, start, anchor time.Time) (map[string]int64, error) {
	rows, err := tx.Query(ctx, autopilotRewardCohortCandidatesSQL, excluded, start, anchor)
	if err != nil {
		return nil, err
	}
	type peer struct {
		ID        string   `json:"id"`
		Account   string   `json:"account"`
		Ancestors []string `json:"ancestors"`
	}
	var matching []peer
	for rows.Next() {
		var candidate peer
		var observations []byte
		if err := rows.Scan(&candidate.ID, &candidate.Account, &candidate.Ancestors, &observations); err != nil {
			rows.Close()
			return nil, err
		}
		var hardware []*store.MachineObservation
		if err := json.Unmarshal(observations, &hardware); err != nil {
			rows.Close()
			return nil, err
		}
		matches := len(hardware) > 0
		for _, observation := range hardware {
			if observation == nil {
				matches = false
				break
			}
			candidateKey, known := floorpolicy.ParseCohortKey(observation.Chip, observation.MemoryGB)
			if !known || candidateKey != key {
				matches = false
				break
			}
		}
		if matches {
			matching = append(matching, candidate)
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil || len(matching) == 0 {
		return nil, err
	}
	raw, err := json.Marshal(matching)
	if err != nil {
		return nil, err
	}
	rows, err = tx.Query(ctx, autopilotRewardCohortEarningsSQL, raw, start, anchor)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	totals := make(map[string]int64, len(matching))
	for rows.Next() {
		var id string
		var total int64
		var negative, ambiguous bool
		if err := rows.Scan(&id, &total, &negative, &ambiguous); err != nil {
			return nil, fmt.Errorf("store: sum autopilot cohort inference payouts: %w", err)
		}
		if negative {
			return nil, errors.New("negative autopilot inference payout")
		}
		if !ambiguous {
			totals[id] = total
		}
	}
	return totals, rows.Err()
}

const autopilotRewardCohortCandidatesSQL = `WITH RECURSIVE ancestors AS (
 SELECT id AS canonical_id,id,first_seen FROM darkbloom_machines
 WHERE merged_into IS NULL AND assurance<>'provisional' AND id<>$1 AND first_seen<=$2
 UNION SELECT a.canonical_id,m.id,m.first_seen FROM darkbloom_machines m JOIN ancestors a ON m.merged_into=a.id
), members AS MATERIALIZED (
 SELECT a.canonical_id,s.* FROM ancestors a JOIN darkbloom_machine_sessions s ON s.machine_id=a.id
), owner_evidence AS (
 SELECT canonical_id,account_id FROM members
 UNION SELECT m.canonical_id,p.account_id FROM members m JOIN provider_sessions p USING(session_id)
 UNION SELECT a.canonical_id,e.account_id FROM ancestors a JOIN autopilot_reward_enrollments e ON e.machine_id=a.id
 UNION SELECT a.canonical_id,c.account_id FROM ancestors a JOIN autopilot_reward_consents c ON c.machine_id=a.id
 UNION SELECT m.canonical_id,c.account_id FROM members m JOIN autopilot_reward_consents c USING(session_id)
), owners AS (
 SELECT canonical_id,min(account_id) AS account FROM owner_evidence WHERE account_id<>''
 GROUP BY canonical_id HAVING count(DISTINCT account_id)=1
), mature AS (
 SELECT canonical_id FROM (
  SELECT canonical_id,first_seen FROM ancestors UNION ALL SELECT canonical_id,first_seen FROM members
 ) starts GROUP BY canonical_id HAVING min(first_seen)<=$2
), eligible AS (
 SELECT o.* FROM owners o JOIN mature USING(canonical_id)
 WHERE NOT EXISTS(SELECT 1 FROM erasure_requests e WHERE e.account_id=o.account AND e.state='erased')
 AND NOT EXISTS(SELECT 1 FROM users u WHERE u.account_id=o.account AND u.deleted_at IS NOT NULL)
), hardware AS (
 SELECT m.canonical_id,jsonb_agg(h.observation ORDER BY m.session_id) AS observations
 FROM members m JOIN eligible e USING(canonical_id)
 LEFT JOIN LATERAL (SELECT observation FROM darkbloom_machine_observations o
  WHERE o.session_id=m.session_id AND o.observed_at<=$3 ORDER BY o.observed_at DESC LIMIT 1) h ON TRUE
 WHERE m.first_seen<=$3 GROUP BY m.canonical_id
)
 SELECT e.canonical_id,e.account,array_agg(a.id ORDER BY a.id),h.observations
 FROM eligible e JOIN ancestors a USING(canonical_id) JOIN hardware h USING(canonical_id)
 GROUP BY e.canonical_id,e.account,h.observations ORDER BY e.canonical_id`

// Session identity wins over key reuse. Fallback rows fan out only to possible
// owners, then ambiguous key associations are withheld exactly as in the
// single-machine sum; DISTINCT prevents reconnects multiplying an earning.
const autopilotRewardCohortEarningsSQL = `WITH peers AS MATERIALIZED (
 SELECT * FROM jsonb_to_recordset($1::jsonb) AS p(id text,account text,ancestors text[])
), members AS MATERIALIZED (
 SELECT p.id,p.account,p.ancestors,s.session_id,s.account_id FROM peers p
 JOIN darkbloom_machine_sessions s ON s.machine_id=ANY(p.ancestors)
), earnings AS MATERIALIZED (
 SELECT e.* FROM provider_earnings e WHERE e.created_at>=$2 AND e.created_at<$3 AND e.model<>'base_reward'
 AND e.account_id IN (SELECT account FROM peers)
), attributed AS (
 SELECT m.id,e.id AS earning_id,e.amount_micro_usd,
 EXISTS(SELECT 1 FROM provider_sessions p WHERE p.session_id=e.provider_id AND p.account_id<>'' AND p.account_id<>e.account_id) AS ambiguous
 FROM earnings e JOIN members m ON m.session_id=e.provider_id AND m.account_id=e.account_id AND m.account=e.account_id
 UNION ALL
 SELECT DISTINCT m.id,e.id AS earning_id,e.amount_micro_usd,
 EXISTS(SELECT 1 FROM provider_sessions p WHERE p.session_id=e.provider_id AND p.account_id<>'' AND p.account_id<>e.account_id)
 OR EXISTS(SELECT 1 FROM provider_sessions p JOIN darkbloom_machine_sessions s USING(session_id)
  WHERE p.provider_key=e.provider_key AND p.account_id=e.account_id
  AND (s.account_id<>e.account_id OR NOT s.machine_id=ANY(m.ancestors))) AS ambiguous
 FROM earnings e JOIN provider_sessions p ON p.provider_key=e.provider_key AND p.account_id=e.account_id
 JOIN members m ON m.session_id=p.session_id AND m.account_id=e.account_id AND m.account=e.account_id
 WHERE e.provider_key<>'' AND NOT EXISTS(SELECT 1 FROM darkbloom_machine_sessions s WHERE s.session_id=e.provider_id)
)
 SELECT p.id,COALESCE(sum(a.amount_micro_usd),0),COALESCE(bool_or(a.amount_micro_usd<0),false),COALESCE(bool_or(a.ambiguous),false)
 FROM peers p LEFT JOIN attributed a ON a.id=p.id GROUP BY p.id ORDER BY p.id`
