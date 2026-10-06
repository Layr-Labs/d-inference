package postgres

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (s *PostgresStore) PrepareGlobalRecipient(r store.GlobalRecipient) (*store.GlobalRecipient, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	data, err := json.Marshal(r)
	if err != nil {
		return nil, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer rollbackErasureTx(tx)
	if err := lockAccountAdmission(ctx, tx, r.AccountID); err != nil {
		return nil, err
	}
	var result store.GlobalRecipient
	err = readPayoutJSON(tx.QueryRow(ctx, `INSERT INTO global_payout_recipients(account_id,country,data) VALUES($1,$2,$3)
 ON CONFLICT(account_id) DO UPDATE SET country=EXCLUDED.country,
 data=CASE WHEN global_payout_recipients.country=EXCLUDED.country THEN global_payout_recipients.data ELSE EXCLUDED.data END RETURNING data`, r.AccountID, r.Country, data), &result)
	if err != nil {
		return nil, err
	}
	return &result, tx.Commit(ctx)
}

func (s *PostgresStore) SaveGlobalRecipient(r store.GlobalRecipient) error {
	ctx, cancel := payoutContext()
	defer cancel()
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer rollbackErasureTx(tx)
	deleted, err := fenceErasureExternalObject(ctx, tx, r.AccountID, store.ErasureTargetGlobalRecipient, r.RecipientID)
	if err != nil {
		return err
	}
	if deleted {
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		return store.ErrErasureConflict
	}
	result, err := tx.Exec(ctx, `UPDATE global_payout_recipients SET data=$2 WHERE account_id=$1 AND data->>'id'=$3`, r.AccountID, data, r.ID)
	if err == nil && result.RowsAffected() != 1 {
		return store.ErrPayoutConflict
	}
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *PostgresStore) GetGlobalRecipient(accountID string) (*store.GlobalRecipient, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	var r store.GlobalRecipient
	err := readPayoutJSON(s.pool.QueryRow(ctx, `SELECT data FROM global_payout_recipients WHERE account_id=$1`, accountID), &r)
	return &r, err
}

func (s *PostgresStore) RemoveGlobalRecipient(accountID string) error {
	ctx, cancel := payoutContext()
	defer cancel()
	// Retain a generation tombstone: unlink must never restore legacy Connect routing.
	data, err := json.Marshal(store.GlobalRecipient{ID: uuid.NewString(), AccountID: accountID})
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `UPDATE global_payout_recipients SET country='', data=$2 WHERE account_id=$1`, accountID, data)
	return err
}
