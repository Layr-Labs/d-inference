package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) ResolveMachineContinuity(ctx context.Context, sessionID, account, key string, excluded []string) (MachineContinuity, error) {
	var result MachineContinuity
	if sessionID == "" || account == "" || key == "" {
		return result, ErrMachineContinuityUnverified
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// Both reads see the same alias/merge/revocation snapshot. This lookup never
	// performs network verification or writes identities, balances or trust.
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return result, err
	}
	defer tx.Rollback(ctx)
	alias := appAttestMachineAlias(account, key)
	err = tx.QueryRow(ctx, `SELECT m.id,m.assurance
	 FROM darkbloom_machine_sessions s
	 JOIN darkbloom_machines m ON m.id=s.machine_id AND m.merged_into IS NULL
	 JOIN darkbloom_machine_aliases a ON a.machine_id=m.id AND a.kind='app_attest' AND a.scope=$2 AND a.digest=$4
	 JOIN app_attest_shadow_keys k ON k.key_id=$3 AND k.evidence->>'account_id'=$2
	 WHERE s.session_id=$1 AND s.account_id=$2 AND s.disconnected_at IS NULL
	 AND m.assurance <> 'provisional'
	 AND NOT EXISTS(SELECT 1 FROM app_attest_key_revocations r WHERE r.key_id=$3)`, sessionID, account, key, alias.Digest).Scan(&result.Machine.ID, &result.Machine.Assurance)
	if errors.Is(err, pgx.ErrNoRows) {
		return MachineContinuity{}, ErrMachineContinuityUnverified
	}
	if err != nil {
		return MachineContinuity{}, err
	}
	if excluded == nil {
		excluded = []string{}
	}
	// Never restore through serial or SE claims, and never cross account history
	// even when an Apple-verified MDA serial associates two account-scoped aliases.
	result.Previous, err = scanProviderRecord(tx.QueryRow(ctx, `SELECT `+providerRecordColumns+`
	 FROM providers WHERE account_id=$2 AND id<>$3 AND id<>ALL($4::text[])
	 AND id IN (SELECT session_id FROM darkbloom_machine_sessions WHERE machine_id=$1 AND account_id=$2)
	 ORDER BY last_seen DESC,id DESC LIMIT 1`, result.Machine.ID, account, sessionID, excluded))
	if errors.Is(err, pgx.ErrNoRows) {
		result.Previous, err = nil, nil
	}
	if err != nil {
		return MachineContinuity{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return MachineContinuity{}, err
	}
	return result, nil
}
