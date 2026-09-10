package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

type providerRecordDB interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}

func (s *PostgresStore) UpsertProviderWithReputation(ctx context.Context, p ProviderRecord, rep ReputationRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := upsertProviderRecord(ctx, tx, p); err != nil {
		return err
	}
	if err := upsertReputationRecord(ctx, tx, p.ID, rep); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *MemoryStore) UpsertProviderWithReputation(ctx context.Context, p ProviderRecord, rep ReputationRecord) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.upsertProviderRecordLocked(p)
	cp := rep
	s.reputationRecords[p.ID] = &cp
	return nil
}
