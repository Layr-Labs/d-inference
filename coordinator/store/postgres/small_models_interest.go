package postgres

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) UpsertSmallModelsInterest(ctx context.Context, record store.SmallModelsInterest) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO small_models_interest (account_id,mac_type,chip,ram_gb)
 VALUES ($1,$2,$3,$4) ON CONFLICT (account_id) DO UPDATE SET
 mac_type=EXCLUDED.mac_type, chip=EXCLUDED.chip, ram_gb=EXCLUDED.ram_gb, updated_at=NOW()`,
		record.AccountID, record.MacType, record.Chip, record.RAMGB)
	return err
}

func (s *PostgresStore) GetSmallModelsInterest(ctx context.Context, accountID string) (*store.SmallModelsInterest, error) {
	var record store.SmallModelsInterest
	err := s.pool.QueryRow(ctx, `SELECT account_id,mac_type,chip,ram_gb,created_at,updated_at
 FROM small_models_interest WHERE account_id=$1`, accountID).Scan(
		&record.AccountID, &record.MacType, &record.Chip, &record.RAMGB, &record.CreatedAt, &record.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, store.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &record, nil
}

func (s *PostgresStore) ListSmallModelsInterest(ctx context.Context, after string, limit int) ([]store.SmallModelsInterestContact, error) {
	rows, err := s.pool.Query(ctx, `SELECT i.account_id,i.mac_type,i.chip,i.ram_gb,i.created_at,i.updated_at,u.email
 FROM small_models_interest i JOIN users u ON u.account_id=i.account_id
 WHERE i.account_id > $1 ORDER BY i.account_id LIMIT $2`, after, shared.SmallModelsInterestPageLimit(limit))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []store.SmallModelsInterestContact{}
	for rows.Next() {
		var record store.SmallModelsInterestContact
		if err := rows.Scan(&record.AccountID, &record.MacType, &record.Chip, &record.RAMGB, &record.CreatedAt, &record.UpdatedAt, &record.Email); err != nil {
			return nil, err
		}
		result = append(result, record)
	}
	return result, rows.Err()
}
