package postgres

import (
	"context"
	"fmt"
	"time"

	routesql "github.com/eigeninference/d-inference/coordinator/internal/store/routesql"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// Per-statement deadlines. A batch statement carries up to
// maxInferenceRouteInsertRows rows (or a whole pipelined group of updates),
// so it gets a longer budget than the single-row write.
const (
	inferenceRouteWriteTimeout      = 5 * time.Second
	inferenceRouteBatchWriteTimeout = 10 * time.Second
)

// RecordInferenceRoute writes the routing decision snapshot for a request
// attempt. Callers keep this best-effort by logging returned errors off the
// request path rather than blocking inference.
func (s *PostgresStore) RecordInferenceRoute(record *store.InferenceRouteRecord) error {
	if record == nil {
		return nil
	}
	if err := s.execInferenceRouteInsert([]*store.InferenceRouteRecord{record}, inferenceRouteWriteTimeout); err != nil {
		return fmt.Errorf("store: record inference route: %w", err)
	}
	return nil
}

// RecordInferenceRoutes writes many routing decision snapshots as one
// multi-row upsert per chunk (see splitInferenceRouteBatches for the chunking
// rules). Each chunk is a single statement and therefore atomic; a failure
// stops at the failing chunk and is returned. Re-running the same records is
// safe: the upsert is idempotent.
func (s *PostgresStore) RecordInferenceRoutes(records []*store.InferenceRouteRecord) error {
	for _, chunk := range routesql.SplitBatches(records, routesql.MaxInsertRows) {
		if err := s.execInferenceRouteInsert(chunk, inferenceRouteBatchWriteTimeout); err != nil {
			return fmt.Errorf("store: record inference routes (%d rows): %w", len(chunk), err)
		}
	}
	return nil
}

// execInferenceRouteInsert issues one multi-row upsert for rows. The caller
// guarantees rows is non-empty and free of duplicate (request_id, attempt)
// keys. A zero CreatedAt/UpdatedAt is defaulted per record from its own
// time.Now(), exactly as sequential single-row calls would stamp it (the
// memory store does the same), so batch and single paths agree.
func (s *PostgresStore) execInferenceRouteInsert(rows []*store.InferenceRouteRecord, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	tx, err := beginErasureObservation(ctx, s.pool)
	if err != nil {
		return err
	}
	defer rollbackErasureTx(tx)
	hashes, providers := make([]string, 0, len(rows)), make([]string, 0, len(rows))
	for _, r := range rows {
		hashes = append(hashes, r.ConsumerKeyHash)
		providers = append(providers, r.ProviderID)
	}
	erasedConsumers, erasedProviders, err := erasedObservationOwners(ctx, tx, hashes, providers)
	if err != nil {
		return err
	}
	args := make([]any, 0, len(rows)*routesql.InsertParamCount)
	for _, r := range rows {
		rec := *r
		if erasedConsumers[rec.ConsumerKeyHash] {
			rec.ConsumerRegion = ""
		}
		if erasedProviders[rec.ProviderID] {
			rec.ProviderRegion = ""
		}
		args = routesql.InsertArgs(args, &rec, time.Now().UTC())
	}
	if _, err := tx.Exec(ctx, routesql.InsertSQL(len(rows)), args...); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// UpdateInferenceRouteOutcome updates the attempt with final outcome data
// (tokens, timing, error). Callers keep this best-effort by logging returned
// errors off the request path rather than blocking inference.
func (s *PostgresStore) UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *store.InferenceRouteOutcome) error {
	if outcome == nil {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), inferenceRouteWriteTimeout)
	defer cancel()

	_, err := s.pool.Exec(ctx, routesql.OutcomeUpdateSQL, routesql.OutcomeUpdateArgs(requestID, attempt, outcome)...)
	if err != nil {
		return fmt.Errorf("store: update inference route outcome: %w", err)
	}
	return nil
}

// UpdateInferenceRouteOutcomes pipelines the outcome updates as one pgx batch:
// every statement is the same UPDATE UpdateInferenceRouteOutcome issues, they
// execute on the server in slice order, and the whole group costs one network
// round trip instead of one per update.
//
// pgx runs a batch in an implicit transaction, so a statement that errors
// aborts the statements after it and rolls the group back; the first error is
// returned. Re-running the same updates afterwards is safe: every assignment
// is "set when non-zero / OR into", so re-applying a value is a no-op.
func (s *PostgresStore) UpdateInferenceRouteOutcomes(updates []store.InferenceRouteOutcomeUpdate) error {
	batch := &pgx.Batch{}
	for i := range updates {
		u := &updates[i]
		if u.Outcome == nil {
			continue
		}
		batch.Queue(routesql.OutcomeUpdateSQL, routesql.OutcomeUpdateArgs(u.RequestID, u.Attempt, u.Outcome)...)
	}
	if batch.Len() == 0 {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), inferenceRouteBatchWriteTimeout)
	defer cancel()

	results := s.pool.SendBatch(ctx, batch)
	var firstErr error
	for i := 0; i < batch.Len(); i++ {
		if _, err := results.Exec(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if err := results.Close(); err != nil && firstErr == nil {
		firstErr = err
	}
	if firstErr != nil {
		return fmt.Errorf("store: update inference route outcomes (%d rows): %w", batch.Len(), firstErr)
	}
	return nil
}
