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
// Its result therefore reacquires the account fence. After scrub, cleanup is
// persisted instead of resurrecting an external identifier on a local row.
// During grace, the normal row retains it for the eventual scrub or cancel.
func fenceErasureExternalObject(ctx context.Context, tx pgx.Tx, accountID string, target store.ErasureTarget, externalID string) (deleted, erased bool, err error) {
	var at *time.Time
	err = tx.QueryRow(ctx, `SELECT deleted_at FROM users WHERE account_id=$1 FOR UPDATE`, accountID).Scan(&at)
	if noRows(err) {
		return false, false, nil
	}
	if err != nil {
		return false, false, err
	}
	if at == nil {
		return false, false, nil
	}
	q := storedb.New(tx)
	req, err := q.GetLatestErasureRequest(ctx, accountID)
	if noRows(err) {
		return true, false, nil
	}
	if err != nil {
		return false, false, err
	}
	if req.State != string(store.ErasureErased) && req.State != string(store.ErasurePending) {
		return true, false, nil
	}
	if externalID != "" {
		_, err = tx.Exec(ctx, `INSERT INTO erasure_outbox(id,request_id,target,external_id,next_at)
 SELECT $1,$2,$3,$4,NOW() WHERE NOT EXISTS (
 SELECT 1 FROM erasure_outbox WHERE request_id=$2 AND target=$3 AND external_id=$4 AND state='pending')`, uuid.NewString(), req.ID, string(target), externalID)
	}
	return true, req.State == string(store.ErasureErased), err
}
