package postgres

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// UsageByConsumer returns usage records for a specific consumer key.
func (s *PostgresStore) UsageByConsumer(consumerKey string) []store.UsageRecord {
	h := store.HashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, public_model, prompt_tokens, cached_tokens, completion_tokens, created_at, request_id, cost_micro_usd
			 FROM usage WHERE consumer_key_hash = $1 ORDER BY created_at DESC LIMIT 100`, h)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []store.UsageRecord
	for rows.Next() {
		var r store.UsageRecord
		if err := rows.Scan(&r.ProviderID, &r.ConsumerKey, &r.Model, &r.PublicModel, &r.PromptTokens, &r.CachedTokens, &r.CompletionTokens, &r.CreatedAt, &r.RequestID, &r.CostMicroUSD); err != nil {
			continue
		}
		records = append(records, r)
	}
	return records
}

// RecordUsage inserts a usage row (consumer key stored as its hash) and folds
// the token counts into usage_totals in the same statement. Cached tokens are
// a subset of prompt tokens, so the totals count prompt tokens once. A failed
// insert is logged rather than returned: billing has already settled, but a
// missing row is an audit gap (usage history, per-key spend) that must not
// disappear silently.
func (s *PostgresStore) RecordUsage(rec store.UsageRecord) {
	h := store.HashKey(rec.ConsumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := beginErasureObservation(ctx, s.pool)
	if err != nil {
		slog.Error("store: begin usage write failed", "request_id", rec.RequestID, "error", err)
		return
	}
	defer rollbackErasureTx(tx)
	erased, _, err := erasedObservationOwners(ctx, tx, []string{h}, nil)
	if err != nil {
		slog.Error("store: fence usage location failed", "request_id", rec.RequestID, "error", err)
		return
	}
	if erased[h] {
		rec.RequestLocation = nil
	}
	_, err = tx.Exec(ctx,
		`WITH ins AS (
			INSERT INTO usage (provider_id, consumer_key_hash, key_id, model, public_model, prompt_tokens, cached_tokens, completion_tokens, request_id, cost_micro_usd, request_location)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		)
		UPDATE usage_totals SET
			total_requests = total_requests + 1,
			total_prompt_tokens = total_prompt_tokens + $6,
			total_completion_tokens = total_completion_tokens + $8
		WHERE id = 1`,
		rec.ProviderID, h, rec.KeyID, rec.Model, rec.PublicModel, rec.PromptTokens, rec.CachedTokens, rec.CompletionTokens,
		rec.RequestID, rec.CostMicroUSD, marshalProviderLocation(rec.RequestLocation),
	)
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		slog.Error("store: record usage failed", "request_id", rec.RequestID, "model", rec.Model, "error", err)
	}
}

func nullSince(since time.Time) any {
	if since.IsZero() {
		return nil
	}
	return since
}

// UsageCountSince returns the number of usage records created at or after the
// given time. Uses idx_usage_created for an index-only count. A statement that
// cannot complete is reported as an error, never as a zero count.
func (s *PostgresStore) UsageCountSince(since time.Time) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var count int64
	if err := s.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM usage
		 WHERE ($1::timestamptz IS NULL OR created_at >= $1)`,
		nullSince(since),
	).Scan(&count); err != nil {
		return 0, fmt.Errorf("store: usage count: %w", err)
	}
	return count, nil
}

// UsageTotals returns aggregated lifetime totals from the materialized
// usage_totals counter row. This is a single PK lookup — O(1) regardless
// of how many rows exist in the usage table. A statement that cannot complete
// is reported as an error, never as zero totals. Boot guarantees the row
// (checkRetiredBackfills seeds it on an empty usage table and refuses to
// start without it), so the no-row case reads as zero only if the row is
// deleted while the coordinator runs.
func (s *PostgresStore) UsageTotals() (store.UsageTotals, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var t store.UsageTotals
	err := s.pool.QueryRow(ctx,
		`SELECT total_requests, total_prompt_tokens, total_completion_tokens
		 FROM usage_totals WHERE id = 1`,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.UsageTotals{}, nil
	}
	if err != nil {
		return store.UsageTotals{}, fmt.Errorf("store: usage totals: %w", err)
	}
	return t, nil
}

// UsageTotalsSince returns aggregate usage at or after `since`. A statement
// that cannot complete is reported as an error, never as zero totals.
func (s *PostgresStore) UsageTotalsSince(since time.Time) (store.UsageTotals, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var t store.UsageTotals
	if err := s.pool.QueryRow(ctx,
		`SELECT COUNT(*),
		        COALESCE(SUM(prompt_tokens), 0),
		        COALESCE(SUM(completion_tokens), 0)
		 FROM usage
		 WHERE created_at >= $1`,
		since,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens); err != nil {
		return store.UsageTotals{}, fmt.Errorf("store: usage totals since: %w", err)
	}
	return t, nil
}

// UsageTimeSeries returns usage buckets at or after `since` using a bounded,
// caller-selected interval so long windows do not return tens of thousands of
// minute rows. A statement that cannot complete — including one that times
// out mid-iteration — is reported as an error, never as a partial series.
func (s *PostgresStore) UsageTimeSeries(since, until time.Time, bucketSize time.Duration) ([]store.UsageBucket, error) {
	since, until, bucketSize = shared.NormalizeUsageTimeSeriesRequest(since, until, bucketSize, time.Now())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`WITH bounded AS (
		   SELECT to_timestamp(
		            floor(extract(epoch FROM created_at) / $3::double precision) * $3::double precision
		          ) AS bucket_start,
		          COUNT(*) AS requests,
		          COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
		          COALESCE(SUM(completion_tokens), 0) AS completion_tokens
		   FROM usage
		   WHERE created_at >= $1 AND created_at < $2
		   GROUP BY 1
		   ORDER BY 1 DESC
		   LIMIT $4
		 )
		 SELECT bucket_start, requests, prompt_tokens, completion_tokens
		 FROM bounded
		 ORDER BY bucket_start ASC`,
		since,
		until,
		bucketSize.Seconds(),
		shared.UsageTimeSeriesMaxBuckets,
	)
	if err != nil {
		return nil, fmt.Errorf("store: usage time series: %w", err)
	}
	defer rows.Close()

	var buckets []store.UsageBucket
	for rows.Next() {
		var b store.UsageBucket
		if err := rows.Scan(&b.Minute, &b.Requests, &b.PromptTokens, &b.CompletionTokens); err != nil {
			return nil, fmt.Errorf("store: usage time series: scan: %w", err)
		}
		buckets = append(buckets, b)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: usage time series: %w", err)
	}
	return shared.LimitUsageTimeSeriesBuckets(buckets), nil
}
