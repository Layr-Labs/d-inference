package postgres

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// Call under the shared personal-data fence. These reads deliberately take no
// user row locks: scrub takes its user lock before the exclusive privacy fence.
func checkPersonalAccount(ctx context.Context, tx pgx.Tx, account string) error {
	var erased bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM erasure_requests WHERE account_id=$1 AND state='erased')`, account).Scan(&erased); err != nil {
		return err
	}
	if erased {
		return store.ErrErasureConflict
	}
	return nil
}

func checkPersonalSession(ctx context.Context, tx pgx.Tx, session, account string) error {
	if err := checkPersonalAccount(ctx, tx, account); err != nil {
		return err
	}
	_, erased, err := erasedObservationOwners(ctx, tx, nil, []string{session})
	if err != nil {
		return err
	}
	if erased[session] {
		return store.ErrErasureConflict
	}
	return nil
}

// Evidence must keep its originating account link even before registry's
// asynchronous provider persistence arrives. Session rows are durable ownership
// history; inserting/backfilling that link never reopens a closed session.
func bindEvidenceAccount(ctx context.Context, tx pgx.Tx, session, account string) error {
	if account == "" {
		return nil
	}
	_, err := tx.Exec(ctx, `INSERT INTO provider_sessions(session_id,account_id) VALUES($1,$2)
 ON CONFLICT(session_id) DO UPDATE SET account_id=EXCLUDED.account_id
 WHERE provider_sessions.account_id=''`, session, account)
	return err
}

// Receipts are key-scoped: a live co-owner may still renew a shared key after
// another account's evidence is scrubbed. Unknown legacy ownership is retained.
func checkReceiptOwner(ctx context.Context, tx pgx.Tx, key string) error {
	rows, err := tx.Query(ctx, `SELECT DISTINCT session_id FROM app_attest_evidence WHERE key_id=$1`, key)
	if err != nil {
		return err
	}
	var sessions []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		sessions = append(sessions, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	_, erased, err := erasedObservationOwners(ctx, tx, nil, sessions)
	if err != nil {
		return err
	}
	if len(sessions) > 0 && len(erased) == len(sessions) {
		return store.ErrErasureConflict
	}
	return nil
}

func checkCodeAttestationOwner(ctx context.Context, tx pgx.Tx, key, account string) error {
	var erased, live bool
	err := tx.QueryRow(ctx, `WITH owners AS (
 SELECT account_id FROM providers WHERE se_public_key=$1 UNION SELECT $2::text WHERE $2<>''
 ) SELECT EXISTS(SELECT 1 FROM owners o JOIN erasure_requests r USING(account_id) WHERE r.state='erased'),
 EXISTS(SELECT 1 FROM owners o WHERE NOT EXISTS(SELECT 1 FROM erasure_requests r WHERE r.account_id=o.account_id AND r.state='erased'))`, key, account).Scan(&erased, &live)
	if err != nil {
		return err
	}
	if erased && !live {
		return store.ErrErasureConflict
	}
	return nil
}
