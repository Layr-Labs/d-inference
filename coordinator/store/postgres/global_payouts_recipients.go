package postgres

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) PrepareGlobalRecipient(r contracts.GlobalRecipient) (*contracts.GlobalRecipient, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	data, err := json.Marshal(r)
	if err != nil {
		return nil, err
	}
	var result contracts.GlobalRecipient
	err = readPayoutJSON(s.pool.QueryRow(ctx, `INSERT INTO global_payout_recipients(account_id,country,data) VALUES($1,$2,$3)
 ON CONFLICT(account_id) DO UPDATE SET country=EXCLUDED.country,
 data=CASE WHEN global_payout_recipients.country=EXCLUDED.country THEN global_payout_recipients.data ELSE EXCLUDED.data END RETURNING data`, r.AccountID, r.Country, data), &result)
	return &result, err
}

func (s *Store) SaveGlobalRecipient(r contracts.GlobalRecipient) error {
	ctx, cancel := payoutContext()
	defer cancel()
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	result, err := s.pool.Exec(ctx, `UPDATE global_payout_recipients SET data=$2 WHERE account_id=$1 AND data->>'id'=$3`, r.AccountID, data, r.ID)
	if err == nil && result.RowsAffected() != 1 {
		return contracts.ErrPayoutConflict
	}
	return err
}

func (s *Store) GetGlobalRecipient(accountID string) (*contracts.GlobalRecipient, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	var r contracts.GlobalRecipient
	err := readPayoutJSON(s.pool.QueryRow(ctx, `SELECT data FROM global_payout_recipients WHERE account_id=$1`, accountID), &r)
	return &r, err
}

func (s *Store) RemoveGlobalRecipient(accountID string) error {
	ctx, cancel := payoutContext()
	defer cancel()
	_, err := s.pool.Exec(ctx, `DELETE FROM global_payout_recipients WHERE account_id=$1`, accountID)
	return err
}
