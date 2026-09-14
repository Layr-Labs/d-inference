package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

type AppAttestEnrollment struct {
	ID           string    `json:"id"`
	Owner        string    `json:"owner"`
	KeyID        string    `json:"key_id"`
	CreatedAt    time.Time `json:"created_at"`
	Environment  string    `json:"environment"`
	AppID        string    `json:"app_id"`
	Challenge    string    `json:"challenge"`
	PublicKey    string    `json:"public_key"`
	AccountScope string    `json:"account_scope"`
}

type AppAttestEnrollmentStore interface {
	SaveAppAttestEnrollment(context.Context, AppAttestEnrollment) error
	GetAppAttestEnrollment(context.Context, string) (*AppAttestEnrollment, error)
}

const appAttestEnrollmentDDL = `CREATE TABLE IF NOT EXISTS app_attest_enrollments (id TEXT PRIMARY KEY,owner TEXT NOT NULL,key_id TEXT NOT NULL,created_at TIMESTAMPTZ NOT NULL,context JSONB NOT NULL)`

func (s *PostgresStore) SaveAppAttestEnrollment(ctx context.Context, e AppAttestEnrollment) error {
	raw, err := json.Marshal(e)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO app_attest_enrollments VALUES($1,$2,$3,$4,$5)`, e.ID, e.Owner, e.KeyID, e.CreatedAt, raw)
	return err
}
func (s *PostgresStore) GetAppAttestEnrollment(ctx context.Context, id string) (*AppAttestEnrollment, error) {
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT context FROM app_attest_enrollments WHERE id=$1`, id).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var e AppAttestEnrollment
	err = json.Unmarshal(raw, &e)
	return &e, err
}
func (s *MemoryStore) SaveAppAttestEnrollment(ctx context.Context, e AppAttestEnrollment) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestEnrollments == nil {
		s.appAttestEnrollments = map[string]AppAttestEnrollment{}
	}
	if _, ok := s.appAttestEnrollments[e.ID]; ok {
		return errors.New("enrollment_conflict")
	}
	s.appAttestEnrollments[e.ID] = e
	return nil
}
func (s *MemoryStore) GetAppAttestEnrollment(ctx context.Context, id string) (*AppAttestEnrollment, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	e, ok := s.appAttestEnrollments[id]
	if !ok {
		return nil, nil
	}
	return &e, nil
}
