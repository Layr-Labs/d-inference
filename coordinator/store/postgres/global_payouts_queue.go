package postgres

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
	"time"
)

func (s *PostgresStore) StartUnsentGlobalPayout(id string, leaseUntil time.Time, request, fees json.RawMessage, destinationAmount int64, expiresAt, now time.Time) error {
	ctx, cancel := payoutContext()
	defer cancel()
	_, err := s.mutateGlobalPayout(ctx, id, func(_ pgx.Tx, p *store.GlobalPayout) (bool, error) {
		err := shared.StartUnsentGlobalPayout(p, leaseUntil, request, fees, destinationAmount, expiresAt, now)
		return err == nil, err
	})
	return err
}

func (s *PostgresStore) StartGlobalPayoutDispatch(id string, leaseUntil, now time.Time) error {
	ctx, cancel := payoutContext()
	defer cancel()
	_, err := s.mutateGlobalPayout(ctx, id, func(_ pgx.Tx, p *store.GlobalPayout) (bool, error) {
		err := shared.StartGlobalPayoutDispatch(p, leaseUntil, now)
		return err == nil, err
	})
	return err
}
