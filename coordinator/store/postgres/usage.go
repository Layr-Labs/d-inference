package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/usagetime"
	"github.com/jackc/pgx/v5"
)

// RecordUsage inserts a usage record into PostgreSQL.
func (s *Store) RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int) {
	h := contracts.HashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, _ = s.pool.Exec(ctx,
		`WITH ins AS (
			INSERT INTO usage (provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens)
			VALUES ($1, $2, $3, $4, $5)
		)
		UPDATE usage_totals SET
			total_requests = total_requests + 1,
			total_prompt_tokens = total_prompt_tokens + $4,
			total_completion_tokens = total_completion_tokens + $5
		WHERE id = 1`,
		providerID, h, model, promptTokens, completionTokens,
	)
}

// UsageByConsumer returns usage records for a specific consumer key.
func (s *Store) UsageByConsumer(consumerKey string) []contracts.UsageRecord {
	h := contracts.HashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, public_model, prompt_tokens, completion_tokens, created_at, request_id, cost_micro_usd
			 FROM usage WHERE consumer_key_hash = $1 ORDER BY created_at DESC LIMIT 100`, h)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []contracts.UsageRecord
	for rows.Next() {
		var r contracts.UsageRecord
		if err := rows.Scan(&r.ProviderID, &r.ConsumerKey, &r.Model, &r.PublicModel, &r.PromptTokens, &r.CompletionTokens, &r.CreatedAt, &r.RequestID, &r.CostMicroUSD); err != nil {
			continue
		}
		records = append(records, r)
	}
	return records
}

// RecordUsageWithCost inserts a usage record with request ID and cost.
func (s *Store) RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64) {
	s.RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID, promptTokens, completionTokens, costMicroUSD, nil)
}

// RecordUsageWithCostAndLocation inserts a usage record with request ID, cost,
// and approximate request-origin location.
func (s *Store) RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *contracts.ProviderLocation) {
	s.RecordUsageFull(providerID, consumerKey, "", model, requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFull inserts a usage record with full attribution including the
// originating API key ID for per-key usage and spend tracking.
func (s *Store) RecordUsageFull(providerID, consumerKey, keyID, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *contracts.ProviderLocation) {
	s.RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, "", requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFullWithPublicModel inserts a usage record with full attribution,
// storing both the concrete billing model and optional public display model.
func (s *Store) RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, publicModel, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *contracts.ProviderLocation) {
	h := contracts.HashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, _ = s.pool.Exec(ctx,
		`WITH ins AS (
			INSERT INTO usage (provider_id, consumer_key_hash, key_id, model, public_model, prompt_tokens, completion_tokens, request_id, cost_micro_usd, request_location)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		)
		UPDATE usage_totals SET
			total_requests = total_requests + 1,
			total_prompt_tokens = total_prompt_tokens + $6,
			total_completion_tokens = total_completion_tokens + $7
		WHERE id = 1`,
		providerID, h, keyID, model, publicModel, promptTokens, completionTokens, requestID, costMicroUSD, marshalProviderLocation(requestLocation),
	)
}

func nullSince(since time.Time) any {
	if since.IsZero() {
		return nil
	}
	return since
}

// RecordPayment inserts a payment record into PostgreSQL.
func (s *Store) RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO payments (tx_hash, consumer_address, provider_address, amount_usd, model, prompt_tokens, completion_tokens, memo)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		txHash, consumerAddr, providerAddr, amountUSD, model, promptTokens, completionTokens, memo,
	)
	if err != nil {
		return fmt.Errorf("store: insert payment: %w", err)
	}
	return nil
}

// UsageCountSince returns the number of usage records created at or after the
// given time. Uses idx_usage_created for an index-only count. A statement that
// cannot complete is reported as an error, never as a zero count.
func (s *Store) UsageCountSince(since time.Time) (int64, error) {
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
// is reported as an error, never as zero totals; a database with no counter
// row yet (before the usage_totals migration) genuinely has zero totals.
func (s *Store) UsageTotals() (contracts.UsageTotals, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var t contracts.UsageTotals
	err := s.pool.QueryRow(ctx,
		`SELECT total_requests, total_prompt_tokens, total_completion_tokens
		 FROM usage_totals WHERE id = 1`,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens)
	if errors.Is(err, pgx.ErrNoRows) {
		return contracts.UsageTotals{}, nil
	}
	if err != nil {
		return contracts.UsageTotals{}, fmt.Errorf("store: usage totals: %w", err)
	}
	return t, nil
}

// UsageTotalsSince returns aggregate usage at or after `since`. A statement
// that cannot complete is reported as an error, never as zero totals.
func (s *Store) UsageTotalsSince(since time.Time) (contracts.UsageTotals, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var t contracts.UsageTotals
	if err := s.pool.QueryRow(ctx,
		`SELECT COUNT(*),
		        COALESCE(SUM(prompt_tokens), 0),
		        COALESCE(SUM(completion_tokens), 0)
		 FROM usage
		 WHERE created_at >= $1`,
		since,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens); err != nil {
		return contracts.UsageTotals{}, fmt.Errorf("store: usage totals since: %w", err)
	}
	return t, nil
}

// UsageTimeSeries returns usage buckets at or after `since` using a bounded,
// caller-selected interval so long windows do not return tens of thousands of
// minute rows. A statement that cannot complete — including one that times
// out mid-iteration — is reported as an error, never as a partial series.
func (s *Store) UsageTimeSeries(since, until time.Time, bucketSize time.Duration) ([]contracts.UsageBucket, error) {
	since, until, bucketSize = usagetime.NormalizeRequest(since, until, bucketSize, time.Now())
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
		usagetime.MaxBuckets,
	)
	if err != nil {
		return nil, fmt.Errorf("store: usage time series: %w", err)
	}
	defer rows.Close()

	var buckets []contracts.UsageBucket
	for rows.Next() {
		var b contracts.UsageBucket
		if err := rows.Scan(&b.Minute, &b.Requests, &b.PromptTokens, &b.CompletionTokens); err != nil {
			return nil, fmt.Errorf("store: usage time series: scan: %w", err)
		}
		buckets = append(buckets, b)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: usage time series: %w", err)
	}
	return usagetime.LimitBuckets(buckets), nil
}
