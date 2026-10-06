package postgres

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres/storedb"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// External work cannot hold a database transaction across a remote request.
// Its result therefore reacquires the account fence. For pending or scrubbed
// accounts, cleanup is persisted in the outbox instead of restoring an external
// identifier on a local row.
func fenceErasureExternalObject(ctx context.Context, tx pgx.Tx, accountID string, target store.ErasureTarget, externalID string) (deleted bool, err error) {
	var at *time.Time
	err = tx.QueryRow(ctx, `SELECT deleted_at FROM users WHERE account_id=$1 FOR UPDATE`, accountID).Scan(&at)
	if noRows(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if at == nil {
		return false, nil
	}
	q := storedb.New(tx)
	req, err := q.GetLatestErasureRequest(ctx, accountID)
	if noRows(err) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	if req.State != string(store.ErasureErased) && req.State != string(store.ErasurePending) {
		return true, nil
	}
	if externalID != "" {
		_, err = tx.Exec(ctx, `INSERT INTO erasure_outbox(id,request_id,target,external_id,next_at)
 SELECT $1,$2,$3,$4,NOW() WHERE NOT EXISTS (
 SELECT 1 FROM erasure_outbox WHERE request_id=$2 AND target=$3 AND external_id=$4 AND state='pending')`, uuid.NewString(), req.ID, string(target), externalID)
	}
	return true, err
}
