package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/jackc/pgx/v5"
)

type autopilotRewardMachine struct {
	id        string
	account   string
	ancestors []string
	firstSeen time.Time
}

// The initial lookup supplies the account admission lock. Every caller repeats
// it under the inventory barrier before trusting either ownership or ancestry.
func resolveAutopilotRewardMachine(ctx context.Context, q pgQuerier, machineID string) (autopilotRewardMachine, error) {
	var machine autopilotRewardMachine
	var owners []string
	err := q.QueryRow(ctx, `WITH RECURSIVE chain AS (
	 SELECT id,merged_into,assurance FROM darkbloom_machines WHERE id=$1
	 UNION SELECT m.id,m.merged_into,m.assurance FROM darkbloom_machines m JOIN chain c ON c.merged_into=m.id
	), canonical AS (
	 SELECT id FROM chain WHERE merged_into IS NULL AND assurance<>'provisional'
	), ancestors AS (
	 SELECT m.id,m.first_seen FROM darkbloom_machines m JOIN canonical c ON c.id=m.id
	 UNION SELECT m.id,m.first_seen FROM darkbloom_machines m JOIN ancestors a ON m.merged_into=a.id
	), owners AS (
	 SELECT s.account_id FROM darkbloom_machine_sessions s WHERE s.machine_id IN (SELECT id FROM ancestors)
	 UNION SELECT p.account_id FROM provider_sessions p JOIN darkbloom_machine_sessions s USING(session_id)
	 WHERE s.machine_id IN (SELECT id FROM ancestors)
	 UNION SELECT e.account_id FROM autopilot_reward_enrollments e WHERE e.machine_id IN (SELECT id FROM ancestors)
	 UNION SELECT c.account_id FROM autopilot_reward_consents c WHERE c.machine_id IN (SELECT id FROM ancestors)
	 OR EXISTS (SELECT 1 FROM darkbloom_machine_sessions s WHERE s.session_id=c.session_id AND s.machine_id IN (SELECT id FROM ancestors))
	) SELECT id,ARRAY(SELECT id FROM ancestors ORDER BY id),(SELECT min(first_seen) FROM (
	 SELECT first_seen FROM ancestors UNION ALL SELECT s.first_seen FROM darkbloom_machine_sessions s
	 WHERE s.machine_id IN (SELECT id FROM ancestors)) observations),
	 ARRAY(SELECT account_id FROM owners WHERE account_id<>'' ORDER BY account_id) FROM canonical`, machineID).
		Scan(&machine.id, &machine.ancestors, &machine.firstSeen, &owners)
	if errors.Is(err, pgx.ErrNoRows) {
		return machine, earningsfloor.ErrIdentity
	}
	if err != nil {
		return machine, err
	}
	if len(owners) != 1 {
		return machine, earningsfloor.ErrIdentity
	}
	machine.account = owners[0]
	return machine, nil
}

func (s *PostgresStore) beginAutopilotRewardWrite(ctx context.Context, account string) (pgx.Tx, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	if err := lockAccountAdmission(ctx, tx, account); err != nil {
		rollbackErasureTx(tx)
		return nil, err
	}
	if err := lockPersonalDataWrite(ctx, tx); err != nil {
		rollbackErasureTx(tx)
		return nil, err
	}
	if err := checkPersonalAccount(ctx, tx, account); err != nil {
		rollbackErasureTx(tx)
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(9952701)`); err != nil {
		rollbackErasureTx(tx)
		return nil, err
	}
	return tx, nil
}

func (s *PostgresStore) beginAutopilotRewardMachineWrite(ctx context.Context, machineID string) (pgx.Tx, autopilotRewardMachine, earningsfloor.Pool, error) {
	before, err := resolveAutopilotRewardMachine(ctx, s.pool, machineID)
	if err != nil {
		return nil, before, earningsfloor.Pool{}, err
	}
	tx, err := s.beginAutopilotRewardWrite(ctx, before.account)
	if err != nil {
		return nil, before, earningsfloor.Pool{}, err
	}
	machine, err := resolveAutopilotRewardMachine(ctx, tx, machineID)
	if err == nil && machine.account != before.account {
		err = earningsfloor.ErrIdentity
	}
	var pool earningsfloor.Pool
	if err == nil {
		pool, err = lockAutopilotRewardPool(ctx, tx)
	}
	if err == nil {
		err = bindAutopilotRewardConsents(ctx, tx, machine)
	}
	if err != nil {
		rollbackErasureTx(tx)
		return nil, machine, pool, err
	}
	return tx, machine, pool, nil
}

// Session attribution is authoritative. A legacy key is a fallback only when
// there is no inventory session mapping, and all its same-account associations
// identify this machine. EXISTS avoids multiplying payouts by session count.
func sumAutopilotInference(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine, since, until time.Time) (int64, error) {
	var total int64
	var negative, ambiguous bool
	err := tx.QueryRow(ctx, `WITH attributed AS (
	 SELECT e.amount_micro_usd,
	 EXISTS (SELECT 1 FROM provider_sessions p WHERE p.session_id=e.provider_id AND p.account_id<>'' AND p.account_id<>e.account_id)
	 OR (NOT EXISTS (SELECT 1 FROM darkbloom_machine_sessions s WHERE s.session_id=e.provider_id)
	  AND EXISTS (SELECT 1 FROM provider_sessions p JOIN darkbloom_machine_sessions s USING(session_id)
	   WHERE p.provider_key=e.provider_key AND p.account_id=e.account_id
	   AND (s.account_id<>e.account_id OR NOT s.machine_id=ANY($4::text[])))) AS ambiguous
	 FROM provider_earnings e
	 WHERE e.account_id=$1 AND e.created_at >= $2 AND e.created_at < $3 AND e.model<>'base_reward'
	 AND (
	  EXISTS (SELECT 1 FROM darkbloom_machine_sessions s WHERE s.session_id=e.provider_id
	   AND s.account_id=e.account_id AND s.machine_id=ANY($4::text[]))
	  OR (e.provider_key<>'' AND NOT EXISTS (SELECT 1 FROM darkbloom_machine_sessions s WHERE s.session_id=e.provider_id)
	   AND EXISTS (SELECT 1 FROM provider_sessions p JOIN darkbloom_machine_sessions s USING(session_id)
	    WHERE p.provider_key=e.provider_key AND p.account_id=e.account_id AND s.account_id=e.account_id AND s.machine_id=ANY($4::text[])))
	 )
	) SELECT COALESCE(sum(amount_micro_usd),0),COALESCE(bool_or(amount_micro_usd<0),false),COALESCE(bool_or(ambiguous),false) FROM attributed`,
		machine.account, since, until, machine.ancestors).Scan(&total, &negative, &ambiguous)
	if err != nil {
		return 0, fmt.Errorf("store: sum autopilot inference payouts: %w", err)
	}
	if negative {
		return 0, errors.New("negative autopilot inference payout")
	}
	if ambiguous {
		return 0, earningsfloor.ErrIdentity
	}
	return total, nil
}
