package store

import (
	"context"
	"fmt"
	"github.com/jackc/pgx/v5"
	"time"
)

// analyticsWorkMem is the per-transaction work_mem for the analytics
// statements behind /v1/stats and /v1/network/totals. Each sorts or hashes
// every located usage row of the last 24 h (COUNT(DISTINCT) / GROUP BY over
// ~3 M rows in production); at the instance default of 4 MB that is an
// external merge sort spilling >1 GB of temp files per execution. SET LOCAL
// scopes the raise to the one read-only transaction, so the instance setting
// stays untouched. The budget is per sort/hash node; hash_mem_multiplier is
// pinned to 1.0 in the same transaction so a hash aggregate cannot take
// twice this (the PG 15+ default multiplier is 2.0). Only the cache
// refreshers run these statements — one stats pipeline and one totals
// window at a time — so the transient memory is bounded to a few GB.
const analyticsWorkMem = "1GB"

// withAnalyticsTx runs fn inside one read-only transaction with work_mem
// raised to analyticsWorkMem (and hash_mem_multiplier pinned to 1.0) for that
// transaction only.
func (s *PostgresStore) withAnalyticsTx(ctx context.Context, fn func(pgx.Tx) error) error {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, "SET LOCAL work_mem = '"+analyticsWorkMem+"'"); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "SET LOCAL hash_mem_multiplier = 1.0"); err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// UsageLocationBuckets aggregates usage by approximate request origin. since
// is always a real cutoff (the caller passes now-24h): the former
// `$1 IS NULL OR created_at >= $1` form planned as a parallel sequential scan
// of the whole usage table under a generic plan, so it is not used.
func (s *PostgresStore) UsageLocationBuckets(since time.Time) ([]UsageLocationBucket, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var buckets []UsageLocationBucket
	err := s.withAnalyticsTx(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx,
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
			   AND created_at >= $1
			 GROUP BY city, region, region_code, country, country_code
			 ORDER BY COUNT(*) DESC`,
			since,
		)
		if err != nil {
			return err
		}
		defer rows.Close()
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
				return err
			}
			buckets = append(buckets, b)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, fmt.Errorf("store: usage locations: %w", err)
	}
	return buckets, nil
}

// UsageFlowBuckets aggregates directional consumer→provider flows by JOINing
// the usage table with providers in SQL. This replaces loading all rows into
// Go and doing the aggregation in-process. The query only returns the top 50
// flows (by request count) so the result set is bounded.
func (s *PostgresStore) UsageFlowBuckets(since time.Time, _ map[string]*ProviderLocation) ([]UsageFlowBucket, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var buckets []UsageFlowBucket
	err := s.withAnalyticsTx(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx,
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
			   AND u.created_at >= $1
			 GROUP BY c_city, c_region, c_region_code, c_country, c_country_code,
			          p_city, p_region, p_region_code, p_country, p_country_code
			 ORDER BY requests DESC
			 LIMIT 50`,
			since,
		)
		if err != nil {
			return err
		}
		defer rows.Close()
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
				return err
			}
			buckets = append(buckets, b)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, fmt.Errorf("store: usage flows: %w", err)
	}
	return buckets, nil
}

// NetworkTotals returns aggregated metrics across all earnings for the given
// time window. Zero `since` means all-time. Totals combine inference work
// (provider_earnings) with non-inference reward ledger entries (referral_reward,
// admin_reward), but rewards are only counted for provider accounts (those with
// inference work in the window) so consumer-only reward recipients don't inflate
// network provider totals. ActiveAccounts counts distinct provider accounts.
//
// The statement is three scans of provider_earnings; it runs in its own
// read-only transaction with the same work_mem policy as usage analytics. A failure —
// most often the 10 s timeout — is returned as an error rather than a zero
// row, so the handler never caches or serves all-zero totals.
func (s *PostgresStore) NetworkTotals(since time.Time) (NetworkTotalsRow, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// `since`, when set, is bound once as $1 and referenced in the work,
	// base_reward, providers, and reward subqueries.
	args := []any{}
	workWhere := ` WHERE model <> 'base_reward'`
	baseRewardWhere := ` WHERE model = 'base_reward'`
	providerSince := ""
	rewardSince := ""
	if !since.IsZero() {
		args = append(args, since)
		workWhere += ` AND created_at >= $1`
		baseRewardWhere += ` AND created_at >= $1`
		providerSince = ` AND created_at >= $1`
		rewardSince = ` AND le.created_at >= $1`
	}

	rewardTypes := rewardLedgerTypesSQLList()
	q := `WITH work AS (
	          SELECT COALESCE(SUM(amount_micro_usd),0)                  AS work_micro,
	                 COALESCE(SUM(prompt_tokens + completion_tokens),0) AS tokens,
		                 COUNT(*)                                           AS jobs
		          FROM provider_earnings` + workWhere + `
		      ),
		      base_reward AS (
		          SELECT COALESCE(SUM(amount_micro_usd),0) AS reward_micro
		          FROM provider_earnings` + baseRewardWhere + `
		      ),
		      providers AS (
		          SELECT DISTINCT account_id FROM provider_earnings WHERE account_id != ''` + providerSince + `
	      ),
	      reward AS (
	          SELECT COALESCE(SUM(le.amount_micro_usd),0) AS reward_micro
	          FROM ledger_entries le
	          JOIN providers p ON p.account_id = le.account_id
	          WHERE le.entry_type IN (` + rewardTypes + `)` + rewardSince + `
	      )
	      SELECT work.work_micro + base_reward.reward_micro + reward.reward_micro AS earnings_micro,
	             work.work_micro, base_reward.reward_micro + reward.reward_micro, work.tokens, work.jobs,
	             (SELECT COUNT(*) FROM providers)        AS active_accounts
	      FROM work, base_reward, reward`

	var t NetworkTotalsRow
	err := s.withAnalyticsTx(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, q, args...).
			Scan(&t.EarningsMicroUSD, &t.WorkEarningsMicroUSD, &t.RewardEarningsMicroUSD, &t.Tokens, &t.Jobs, &t.ActiveAccounts)
	})
	if err != nil {
		return NetworkTotalsRow{}, fmt.Errorf("store: network totals: %w", err)
	}
	return t, nil
}
