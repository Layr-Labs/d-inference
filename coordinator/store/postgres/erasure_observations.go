package postgres

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// Observation writers share this transaction lock; only an irreversible scrub
// takes it exclusively. No network or inference work runs while it is held.
// The erased-state read is a later statement, so a writer waiting for a scrub
// observes its committed state before inserting or refreshing personal fields.
func beginErasureObservation(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}) (pgx.Tx, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock_shared(714320, 2)`); err != nil {
		rollbackErasureTx(tx)
		return nil, err
	}
	return tx, nil
}

func erasedObservationOwners(ctx context.Context, tx pgx.Tx, hashes, providers []string) (map[string]bool, map[string]bool, error) {
	rows, err := tx.Query(ctx, `WITH erased AS (
   SELECT account_id FROM erasure_requests WHERE state='erased'
 )
 SELECT 'consumer', encode(sha256(convert_to(account_id, 'UTF8')), 'hex') FROM erased
 WHERE encode(sha256(convert_to(account_id, 'UTF8')), 'hex') = ANY($1::text[])
 UNION ALL
 SELECT 'provider', p.id FROM providers p JOIN erased e USING(account_id) WHERE p.id=ANY($2::text[])
 UNION ALL
 SELECT 'provider', p.session_id FROM provider_sessions p JOIN erased e USING(account_id) WHERE p.session_id=ANY($2::text[])
 UNION ALL
 SELECT 'provider', p.session_id FROM darkbloom_machine_sessions p JOIN erased e USING(account_id) WHERE p.session_id=ANY($2::text[])`, hashes, providers)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	consumers, machines := map[string]bool{}, map[string]bool{}
	for rows.Next() {
		var kind, id string
		if err := rows.Scan(&kind, &id); err != nil {
			return nil, nil, err
		}
		if kind == "consumer" {
			consumers[id] = true
		} else {
			machines[id] = true
		}
	}
	return consumers, machines, rows.Err()
}
