package postgres

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/jackc/pgx/v5"
)

func (s *Store) SaveAppAttestEnrollment(ctx context.Context, e contracts.AppAttestEnrollment) error {
	raw, err := json.Marshal(e)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO app_attest_enrollments VALUES($1,$2,$3,$4,$5)`, e.ID, e.Owner, e.KeyID, e.CreatedAt, raw)
	return err
}

func (s *Store) GetAppAttestEnrollment(ctx context.Context, id string) (*contracts.AppAttestEnrollment, error) {
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT context FROM app_attest_enrollments WHERE id=$1`, id).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var e contracts.AppAttestEnrollment
	err = json.Unmarshal(raw, &e)
	return &e, err
}
