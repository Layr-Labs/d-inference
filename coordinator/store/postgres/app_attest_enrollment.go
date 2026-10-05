package postgres

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

const appAttestEnrollmentDDL = `CREATE TABLE IF NOT EXISTS app_attest_enrollments (id TEXT PRIMARY KEY,owner TEXT NOT NULL,key_id TEXT NOT NULL,created_at TIMESTAMPTZ NOT NULL,context JSONB NOT NULL)`

func (s *PostgresStore) SaveAppAttestEnrollment(ctx context.Context, e store.AppAttestEnrollment) error {
	raw, err := json.Marshal(e)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO app_attest_enrollments VALUES($1,$2,$3,$4,$5)`, e.ID, e.Owner, e.KeyID, e.CreatedAt, raw)
	return err
}

func (s *PostgresStore) GetAppAttestEnrollment(ctx context.Context, id string) (*store.AppAttestEnrollment, error) {
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT context FROM app_attest_enrollments WHERE id=$1`, id).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var e store.AppAttestEnrollment
	err = json.Unmarshal(raw, &e)
	return &e, err
}
