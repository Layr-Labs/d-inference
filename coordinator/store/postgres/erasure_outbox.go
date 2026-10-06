package postgres

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres/storedb"
	"github.com/jackc/pgx/v5"
)

// LeaseDueErasureOutbox leases due outbox rows with FOR UPDATE SKIP LOCKED.
func (s *PostgresStore) LeaseDueErasureOutbox(ctx context.Context, dueBefore, now time.Time, lease time.Duration, limit int) ([]store.ErasureOutboxWork, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	rows, err := s.queries().LeaseDueErasureOutbox(ctx, storedb.LeaseDueErasureOutboxParams{
		DueBefore: dueBefore, Now: now, LeaseUntil: now.Add(lease), MaxRows: int32(limit),
	})
	if err != nil {
		return nil, err
	}
	out := make([]store.ErasureOutboxWork, 0, len(rows))
	for _, r := range rows {
		w := store.ErasureOutboxWork{AccountID: r.AccountID, ErasureOutboxItem: store.ErasureOutboxItem{
			ID: r.ID, RequestID: r.RequestID, Target: store.ErasureTarget(r.Target), State: store.ErasureOutboxState(r.State),
			Attempts: int(r.Attempts), NextAt: r.NextAt, LastError: r.LastError, CreatedAt: r.CreatedAt,
			ExternalID: r.ExternalID, HasExternalID: r.ExternalID != "", StripeJobID: r.StripeJobID, HasStripeJob: r.StripeJobID != "",
			JobStatus: r.StripeJobStatus, JobStatusSince: r.StripeJobStatusSince, JobGeneration: int(r.StripeJobGeneration), LeaseGeneration: r.LeaseGeneration,
		}}
		if r.ErasedAt != nil {
			w.ErasedAt = *r.ErasedAt
		}
		out = append(out, w)
	}
	return out, nil
}

// SaveErasureOutboxResult stores one delivery outcome.
func (s *PostgresStore) SaveErasureOutboxResult(ctx context.Context, id string, r store.ErasureOutboxResult) error {
	return s.erasureTx(ctx, pgx.TxOptions{}, func(ctx context.Context, q *storedb.Queries) error {
		// Acquire the row before checking clock_timestamp in the update: a wait
		// on another transaction must not preserve an already expired claim.
		if err := q.LockErasureOutbox(ctx, id); err != nil {
			return err
		}
		n, err := q.SaveErasureOutboxResult(ctx, storedb.SaveErasureOutboxResultParams{
			ID: id, LeaseGeneration: r.LeaseGeneration, State: string(r.State), Attempts: int32(r.Attempts), NextAt: r.NextAt,
			LastError: r.LastError, ExternalID: r.ExternalID, StripeJobID: r.StripeJobID,
			StripeJobStatus: r.JobStatus, StripeJobStatusSince: r.JobStatusSince, StripeJobGeneration: int32(r.JobGeneration),
		})
		if err != nil {
			return err
		}
		if n == 0 {
			return store.ErrErasureConflict
		}
		if r.Split == nil {
			return nil
		}
		return q.InsertManualErasureOutbox(ctx, storedb.InsertManualErasureOutboxParams{
			ID: r.Split.ID, RequestID: r.Split.RequestID, Target: string(r.Split.Target),
			ExternalID: r.Split.ExternalID, NextAt: r.NextAt, LastError: r.Split.LastError,
		})
	})
}
