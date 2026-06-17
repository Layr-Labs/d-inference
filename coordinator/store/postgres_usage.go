package store

import (
	"context"
	"fmt"
	"strconv"
	"time"
)

// RecordUsage inserts a usage record into PostgreSQL.
func (s *PostgresStore) RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int) {
	h := hashKey(consumerKey)

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
func (s *PostgresStore) UsageByConsumer(consumerKey string) []UsageRecord {
	h := hashKey(consumerKey)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, public_model, prompt_tokens, completion_tokens, created_at, request_id, cost_micro_usd
			 FROM usage WHERE consumer_key_hash = $1 ORDER BY created_at DESC LIMIT 100`, h)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var r UsageRecord
		if err := rows.Scan(&r.ProviderID, &r.ConsumerKey, &r.Model, &r.PublicModel, &r.PromptTokens, &r.CompletionTokens, &r.CreatedAt, &r.RequestID, &r.CostMicroUSD); err != nil {
			continue
		}
		records = append(records, r)
	}
	return records
}

// RecordUsageWithCost inserts a usage record with request ID and cost.
func (s *PostgresStore) RecordUsageWithCost(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64) {
	s.RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID, promptTokens, completionTokens, costMicroUSD, nil)
}

// RecordUsageWithCostAndLocation inserts a usage record with request ID, cost,
// and approximate request-origin location.
func (s *PostgresStore) RecordUsageWithCostAndLocation(providerID, consumerKey, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	s.RecordUsageFull(providerID, consumerKey, "", model, requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFull inserts a usage record with full attribution including the
// originating API key ID for per-key usage and spend tracking.
func (s *PostgresStore) RecordUsageFull(providerID, consumerKey, keyID, model, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	s.RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, "", requestID, promptTokens, completionTokens, costMicroUSD, requestLocation)
}

// RecordUsageFullWithPublicModel inserts a usage record with full attribution,
// storing both the concrete billing model and optional public display model.
func (s *PostgresStore) RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, publicModel, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *ProviderLocation) {
	h := hashKey(consumerKey)

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

// UsageLocationBuckets aggregates usage by approximate request origin.
func (s *PostgresStore) UsageLocationBuckets(since time.Time) []UsageLocationBucket {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT
			COALESCE(request_location->>'city', '') AS city,
			COALESCE(request_location->>'region', '') AS region,
			COALESCE(request_location->>'region_code', '') AS region_code,
			COALESCE(request_location->>'country', '') AS country,
			COALESCE(request_location->>'country_code', '') AS country_code,
			COALESCE(AVG(NULLIF(request_location->>'latitude', '')::double precision), 0),
			COALESCE(AVG(NULLIF(request_location->>'longitude', '')::double precision), 0),
			COUNT(*),
			COALESCE(SUM(prompt_tokens), 0),
			COALESCE(SUM(completion_tokens), 0),
			COUNT(DISTINCT provider_id)
		 FROM usage
		 WHERE request_location IS NOT NULL
		   AND ($1::timestamptz IS NULL OR created_at >= $1)
		 GROUP BY city, region, region_code, country, country_code
		 ORDER BY COUNT(*) DESC`,
		nullSince(since),
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var buckets []UsageLocationBucket
	for rows.Next() {
		var b UsageLocationBucket
		if err := rows.Scan(
			&b.City,
			&b.Region,
			&b.RegionCode,
			&b.Country,
			&b.CountryCode,
			&b.Latitude,
			&b.Longitude,
			&b.Requests,
			&b.PromptTokens,
			&b.CompletionTokens,
			&b.Providers,
		); err != nil {
			continue
		}
		buckets = append(buckets, b)
	}
	return buckets
}

// UsageFlowBuckets aggregates directional consumer→provider flows by JOINing
// the usage table with providers in SQL. This replaces loading all rows into
// Go and doing the aggregation in-process. The query only returns the top 50
// flows (by request count) so the result set is bounded.
func (s *PostgresStore) UsageFlowBuckets(since time.Time, _ map[string]*ProviderLocation) []UsageFlowBucket {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT
			COALESCE(u.request_location->>'city', '')         AS c_city,
			COALESCE(u.request_location->>'region', '')       AS c_region,
			COALESCE(u.request_location->>'region_code', '')  AS c_region_code,
			COALESCE(u.request_location->>'country', '')      AS c_country,
			COALESCE(u.request_location->>'country_code', '') AS c_country_code,
			COALESCE(AVG(NULLIF(u.request_location->>'latitude',  '')::double precision), 0) AS c_lat,
			COALESCE(AVG(NULLIF(u.request_location->>'longitude', '')::double precision), 0) AS c_lng,
			COALESCE(p.location->>'city', '')         AS p_city,
			COALESCE(p.location->>'region', '')       AS p_region,
			COALESCE(p.location->>'region_code', '')  AS p_region_code,
			COALESCE(p.location->>'country', '')      AS p_country,
			COALESCE(p.location->>'country_code', '') AS p_country_code,
			COALESCE(AVG(NULLIF(p.location->>'latitude',  '')::double precision), 0) AS p_lat,
			COALESCE(AVG(NULLIF(p.location->>'longitude', '')::double precision), 0) AS p_lng,
			COUNT(*)                              AS requests,
			COALESCE(SUM(u.prompt_tokens), 0)     AS prompt_tokens,
			COALESCE(SUM(u.completion_tokens), 0) AS completion_tokens
		 FROM usage u
		 JOIN providers p ON p.id = u.provider_id
		 WHERE u.request_location IS NOT NULL
		   AND p.location IS NOT NULL
		   AND ($1::timestamptz IS NULL OR u.created_at >= $1)
		 GROUP BY c_city, c_region, c_region_code, c_country, c_country_code,
		          p_city, p_region, p_region_code, p_country, p_country_code
		 ORDER BY requests DESC
		 LIMIT 50`,
		nullSince(since),
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var buckets []UsageFlowBucket
	for rows.Next() {
		var b UsageFlowBucket
		if err := rows.Scan(
			&b.ConsumerCity, &b.ConsumerRegion, &b.ConsumerRegionCode,
			&b.ConsumerCountry, &b.ConsumerCountryCode,
			&b.ConsumerLatitude, &b.ConsumerLongitude,
			&b.ProviderCity, &b.ProviderRegion, &b.ProviderRegionCode,
			&b.ProviderCountry, &b.ProviderCountryCode,
			&b.ProviderLatitude, &b.ProviderLongitude,
			&b.Requests, &b.PromptTokens, &b.CompletionTokens,
		); err != nil {
			continue
		}
		buckets = append(buckets, b)
	}
	return buckets
}

func nullSince(since time.Time) any {
	if since.IsZero() {
		return nil
	}
	return since
}

// RecordPayment inserts a payment record into PostgreSQL.
func (s *PostgresStore) RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error {
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
// given time. Uses idx_usage_created for an index-only count.
func (s *PostgresStore) UsageCountSince(since time.Time) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var count int64
	_ = s.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM usage
		 WHERE ($1::timestamptz IS NULL OR created_at >= $1)`,
		nullSince(since),
	).Scan(&count)
	return count
}

// UsageTotals returns aggregated lifetime totals from the materialized
// usage_totals counter row. This is a single PK lookup — O(1) regardless
// of how many rows exist in the usage table.
func (s *PostgresStore) UsageTotals() UsageTotals {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var t UsageTotals
	_ = s.pool.QueryRow(ctx,
		`SELECT total_requests, total_prompt_tokens, total_completion_tokens
		 FROM usage_totals WHERE id = 1`,
	).Scan(&t.Requests, &t.PromptTokens, &t.CompletionTokens)
	return t
}

// UsageTimeSeries returns per-minute usage buckets at or after `since`.
func (s *PostgresStore) UsageTimeSeries(since time.Time) []UsageBucket {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT date_trunc('minute', created_at) AS minute,
		        COUNT(*),
		        COALESCE(SUM(prompt_tokens), 0),
		        COALESCE(SUM(completion_tokens), 0)
		 FROM usage
		 WHERE created_at >= $1
		 GROUP BY minute
		 ORDER BY minute ASC`,
		since,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var buckets []UsageBucket
	for rows.Next() {
		var b UsageBucket
		if err := rows.Scan(&b.Minute, &b.Requests, &b.PromptTokens, &b.CompletionTokens); err != nil {
			continue
		}
		buckets = append(buckets, b)
	}
	return buckets
}

// Leaderboard returns the top N accounts ranked by the given metric over the
// given time window. Zero `since` means all-time. The ranking is computed in
// SQL via aggregation on provider_earnings — no per-row wire transfer.
func (s *PostgresStore) Leaderboard(metric LeaderboardMetric, since time.Time, limit int) []LeaderboardRow {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if limit <= 0 || limit > 200 {
		limit = 50
	}

	orderBy := "earnings_micro_usd DESC"
	switch metric {
	case LeaderboardTokens:
		orderBy = "tokens DESC"
	case LeaderboardJobs:
		orderBy = "jobs DESC"
	}

	// account_id != '' filters out unassigned earnings (e.g. legacy wallet-only).
	q := `SELECT account_id,
	             COALESCE(SUM(amount_micro_usd), 0)               AS earnings_micro_usd,
	             COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS tokens,
	             COUNT(*)                                          AS jobs
	      FROM provider_earnings
	      WHERE account_id != ''`
	args := []any{}
	if !since.IsZero() {
		q += ` AND created_at >= $1`
		args = append(args, since)
	}
	q += `
	      GROUP BY account_id
	      ORDER BY ` + orderBy + `
	      LIMIT $` + strconv.Itoa(len(args)+1)
	args = append(args, limit)

	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()

	out := make([]LeaderboardRow, 0, limit)
	for rows.Next() {
		var r LeaderboardRow
		if err := rows.Scan(&r.AccountID, &r.EarningsMicroUSD, &r.Tokens, &r.Jobs); err != nil {
			continue
		}
		out = append(out, r)
	}
	return out
}

// NetworkTotals returns aggregated metrics across all earnings for the given
// time window. Zero `since` means all-time.
func (s *PostgresStore) NetworkTotals(since time.Time) NetworkTotalsRow {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	q := `SELECT COALESCE(SUM(amount_micro_usd), 0),
	             COALESCE(SUM(prompt_tokens + completion_tokens), 0),
	             COUNT(*),
	             COUNT(DISTINCT account_id) FILTER (WHERE account_id != '')
	      FROM provider_earnings`
	args := []any{}
	if !since.IsZero() {
		q += ` WHERE created_at >= $1`
		args = append(args, since)
	}

	var t NetworkTotalsRow
	_ = s.pool.QueryRow(ctx, q, args...).
		Scan(&t.EarningsMicroUSD, &t.Tokens, &t.Jobs, &t.ActiveAccounts)
	return t
}

// UsageRecords returns usage records from the database, ordered by creation time.
// Limited to the most recent 10000 rows as a safety guard against unbounded reads.
func (s *PostgresStore) UsageRecords() []UsageRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, public_model, prompt_tokens, completion_tokens, created_at, request_id, cost_micro_usd, request_location
			 FROM usage ORDER BY created_at DESC LIMIT 10000`,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var r UsageRecord
		var locationRaw []byte
		if err := rows.Scan(
			&r.ProviderID,
			&r.ConsumerKey,
			&r.Model,
			&r.PublicModel,
			&r.PromptTokens,
			&r.CompletionTokens,
			&r.Timestamp,
			&r.RequestID,
			&r.CostMicroUSD,
			&locationRaw,
		); err != nil {
			continue
		}
		r.CreatedAt = r.Timestamp
		r.RequestLocation = unmarshalProviderLocation(locationRaw)
		records = append(records, r)
	}
	if records == nil {
		records = make([]UsageRecord, 0)
	}
	return records
}

// UsageRecordsSince returns usage records created at or after the given time.
func (s *PostgresStore) UsageRecordsSince(since time.Time) []UsageRecord {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, consumer_key_hash, model, public_model, prompt_tokens, completion_tokens, created_at, request_id, cost_micro_usd, request_location
		 FROM usage
		 WHERE ($1::timestamptz IS NULL OR created_at >= $1)
		 ORDER BY created_at ASC`,
		nullSince(since),
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var r UsageRecord
		var locationRaw []byte
		if err := rows.Scan(
			&r.ProviderID,
			&r.ConsumerKey,
			&r.Model,
			&r.PublicModel,
			&r.PromptTokens,
			&r.CompletionTokens,
			&r.Timestamp,
			&r.RequestID,
			&r.CostMicroUSD,
			&locationRaw,
		); err != nil {
			continue
		}
		r.CreatedAt = r.Timestamp
		r.RequestLocation = unmarshalProviderLocation(locationRaw)
		records = append(records, r)
	}
	if records == nil {
		return []UsageRecord{}
	}
	return records
}
