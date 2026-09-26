package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

const modelDemandTableDDL = `CREATE TABLE IF NOT EXISTS model_demand_requests (
 id BIGSERIAL UNIQUE,
 coord_request_id TEXT PRIMARY KEY,
 received_at TIMESTAMPTZ NOT NULL,
 model TEXT NOT NULL,
 consumer_hash TEXT NOT NULL,
 outcome TEXT NOT NULL,
 http_status INTEGER NOT NULL,
 revision BIGINT NOT NULL,
 evidence_conflict BOOLEAN NOT NULL DEFAULT FALSE
)`

// Retained public evidence remains authoritative after the diagnostic ledger
// expires. Receipt/model/consumer identity is immutable at every revision.
const modelDemandProjectionConflictSQL = `model_demand_requests.evidence_conflict OR EXCLUDED.evidence_conflict
 OR model_demand_requests.received_at <> EXCLUDED.received_at
 OR model_demand_requests.model <> EXCLUDED.model
 OR model_demand_requests.consumer_hash <> EXCLUDED.consumer_hash
 OR (model_demand_requests.revision = EXCLUDED.revision AND
     (model_demand_requests.outcome <> EXCLUDED.outcome OR model_demand_requests.http_status <> EXCLUDED.http_status))`

// Read the winning ledger revision inside the SAME transaction. A stale write
// cannot regress the projection, and same-revision conflicts remain unknown.
const projectModelDemandSQL = `INSERT INTO model_demand_requests
 (coord_request_id,received_at,model,consumer_hash,outcome,http_status,revision,evidence_conflict)
 SELECT coord_request_id,received_at,record->'public_demand'->>'model',
 record->'public_demand'->>'consumer_hash',
 CASE WHEN evidence_conflict THEN 'unknown' ELSE record->'public_demand'->>'outcome' END,
 (record->>'http_status')::integer,revision,evidence_conflict
 FROM request_outcomes WHERE coord_request_id=$1 AND record->'public_demand' IS NOT NULL
 ON CONFLICT (coord_request_id) DO UPDATE SET
 outcome=CASE WHEN ` + modelDemandProjectionConflictSQL + ` THEN 'unknown'
   WHEN EXCLUDED.revision > model_demand_requests.revision THEN EXCLUDED.outcome ELSE model_demand_requests.outcome END,
 http_status=CASE WHEN EXCLUDED.revision > model_demand_requests.revision THEN EXCLUDED.http_status ELSE model_demand_requests.http_status END,
 revision=GREATEST(model_demand_requests.revision,EXCLUDED.revision),
 evidence_conflict=` + modelDemandProjectionConflictSQL + `
 WHERE EXCLUDED.revision > model_demand_requests.revision OR ` + modelDemandProjectionConflictSQL

func (s *PostgresStore) ModelDemand(ctx context.Context, since, until time.Time) (ModelDemandSnapshot, error) {
	width := ModelDemandBucketSize(since, until)
	out := ModelDemandSnapshot{BucketSeconds: int64(width / time.Second), Models: []ModelDemandCounts{}}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly, IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SET LOCAL statement_timeout='8s'`); err != nil {
		return out, err
	}
	if _, err = tx.Exec(ctx, `SET LOCAL lock_timeout='1s'`); err != nil {
		return out, err
	}
	if err = tx.QueryRow(ctx, `SELECT started_at FROM model_demand_collection WHERE singleton=TRUE`).Scan(&out.CollectionStartedAt); err != nil {
		return out, err
	}
	rows, err := tx.Query(ctx, `SELECT model,SUM(requests-excluded)::bigint,
 SUM(completed)::bigint,SUM(capacity_rejected)::bigint,SUM(latency_rejected)::bigint,
 SUM(timed_out)::bigint,SUM(failed)::bigint,SUM(cancelled)::bigint,SUM(unknown)::bigint,
 SUM(http_429)::bigint
 FROM model_demand_hourly
 WHERE hour >= $1 AND hour < $2 AND requests > excluded
 GROUP BY model HAVING SUM(requests-excluded) >= $3
 AND COUNT(DISTINCT consumer_hash) >= $4
 ORDER BY SUM(requests-excluded) DESC,model`, since, until, ModelDemandMinRequests, ModelDemandMinConsumers)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var c ModelDemandCounts
		if err = rows.Scan(&c.Model, &c.Requests, &c.Completed, &c.CapacityRejected, &c.LatencyRejected, &c.TimedOut, &c.Failed, &c.Cancelled, &c.Unknown, &c.HTTP429); err != nil {
			return out, err
		}
		out.Models = append(out.Models, c)
	}
	if err = rows.Err(); err != nil {
		return out, err
	}
	rows.Close()
	if err := readModelDemandSeries(ctx, tx, &out, since, until, width); err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}

func (s *PostgresStore) PruneModelDemand(ctx context.Context, before time.Time, batch int) (int, error) {
	n, _, err := s.pruneTelemetryTable(ctx, telemetryTable{name: "model_demand_requests", timeCol: "received_at"}, before, batch)
	if err != nil {
		return n, err
	}
	tag, err := s.pool.Exec(ctx, `DELETE FROM model_demand_hourly WHERE hour < $1`, before.UTC().Truncate(time.Hour))
	return n + int(tag.RowsAffected()), err
}
