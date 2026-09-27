package store

import (
	"context"
	"math"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Keep the pre-fix query as an independent semantics oracle. Unequal per-provider
// sample counts and missing coordinates make unweighted averages incorrect.
const originalLocationAggregateSQL = `SELECT
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
			 ORDER BY COUNT(*) DESC`

func TestUsageLocationBucketsMatchesOriginalAggregate(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	since := time.Date(2026, 9, 4, 0, 0, 0, 0, time.UTC)
	normal := `{"city":"North","region":"Region","region_code":"R","country":"United States","country_code":"US","latitude":"10","longitude":"20"}`
	later := `{"city":"North","region":"Region","region_code":"R","country":"United States","country_code":"US","latitude":"30","longitude":"40"}`
	missing := `{"city":"North","region":"Region","region_code":"R","country":"United States","country_code":"US","latitude":"","longitude":""}`
	partial := `{"city":"North","region":"Region","region_code":"R","country":"United States","country_code":"US","latitude":null,"longitude":"50"}`
	insert := func(provider string, location any, prompt, completion int, at time.Time) {
		t.Helper()
		_, err := s.pool.Exec(ctx, `INSERT INTO usage
   (provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens, created_at, request_location)
   VALUES ($1, 'aggregate-consumer', 'aggregate-model', $2, $3, $4, $5::jsonb)`, provider, prompt, completion, at, location)
		if err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 3; i++ {
		insert("p1", normal, 10, 20, since.Add(time.Hour))
	}
	insert("p2", later, 7, 9, since.Add(time.Hour))
	insert("p2", missing, 0, 1, since.Add(time.Hour))
	insert("", partial, 5, 6, since) // inclusive cutoff; empty ID is still distinct
	insert("p3", `{}`, 2, 3, since.Add(time.Hour))
	insert("p4", `null`, 4, 5, since.Add(time.Hour)) // JSON null is not SQL NULL
	insert("p1", strings.Replace(normal, `"R"`, `"S"`, 1), 6, 7, since.Add(time.Hour))
	insert("p1", strings.Replace(normal, `"US"`, `"CA"`, 1), 8, 9, since.Add(time.Hour))
	insert("expired", normal, 9999, 9999, since.Add(-time.Second))
	insert("unlocated", nil, 9999, 9999, since.Add(time.Hour))

	got, err := s.UsageLocationBuckets(since)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := s.pool.Query(ctx, originalLocationAggregateSQL, since)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var want []UsageLocationBucket
	for rows.Next() {
		var b UsageLocationBucket
		if err := rows.Scan(&b.City, &b.Region, &b.RegionCode, &b.Country, &b.CountryCode,
			&b.Latitude, &b.Longitude, &b.Requests, &b.PromptTokens, &b.CompletionTokens, &b.Providers); err != nil {
			t.Fatal(err)
		}
		want = append(want, b)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(got) != len(want) || len(got) != 4 {
		t.Fatalf("buckets: got %d, want %d (four fixture locations)", len(got), len(want))
	}
	key := func(b UsageLocationBucket) string {
		return strings.Join([]string{b.City, b.Region, b.RegionCode, b.Country, b.CountryCode}, "\x00")
	}
	indexed := make(map[string]UsageLocationBucket, len(want))
	for _, b := range want {
		indexed[key(b)] = b
	}
	for i, b := range got {
		expected, ok := indexed[key(b)]
		if !ok {
			t.Fatalf("unexpected location: %+v", b)
		}
		if math.Abs(b.Latitude-expected.Latitude) > 1e-10 || math.Abs(b.Longitude-expected.Longitude) > 1e-10 {
			t.Fatalf("coordinate averages differ: got %+v, want %+v", b, expected)
		}
		b.Latitude, b.Longitude = expected.Latitude, expected.Longitude
		if !reflect.DeepEqual(b, expected) {
			t.Fatalf("aggregate differs: got %+v, want %+v", b, expected)
		}
		if i > 0 && got[i-1].Requests < b.Requests {
			t.Fatal("buckets are not ordered by descending request count")
		}
	}
	if b := got[0]; b.Requests != 6 || b.Providers != 3 || b.PromptTokens != 42 || b.CompletionTokens != 76 || b.Latitude != 15 || b.Longitude != 30 {
		t.Fatalf("weighted fixture result: %+v", b)
	}
}

func TestUsageLocationPlanChoiceDoesNotLeakToPool(t *testing.T) {
	s, tracer := testPostgresStoreWithTracer(t, func(cfg *pgxpool.Config) {
		cfg.MaxConns = 1 // SHOW below must inspect the query's original connection.
		cfg.ConnConfig.RuntimeParams["plan_cache_mode"] = "force_generic_plan"
	})
	tracer.reset()
	if _, err := s.UsageLocationBuckets(time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	events := tracer.snapshot()
	assertAnalyticsTx(t, events, "FROM usage")
	custom := -1
	for i, event := range events {
		if event.sql == "SET LOCAL plan_cache_mode = force_custom_plan" {
			custom = i
		}
		if strings.Contains(event.sql, "FROM usage") && (custom < 0 || events[custom].pid != event.pid) {
			t.Fatal("location query did not select a custom plan on its transaction connection")
		}
	}
	var mode string
	if err := s.pool.QueryRow(context.Background(), "SHOW plan_cache_mode").Scan(&mode); err != nil {
		t.Fatal(err)
	}
	if mode != "force_generic_plan" {
		t.Fatalf("location query leaked plan_cache_mode=%q into the pool", mode)
	}
}
