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

func TestUsageFlowBucketsMatchesOriginalAggregate(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	since := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
	origin := `{"city":"North","region":"Region","region_code":"R","country":"United States","country_code":"US","latitude":"10","longitude":"20"}`
	destination := strings.Replace(origin, `"North"`, `"South"`, 1)
	for id, location := range map[string]any{
		"p1":             destination,
		"p2":             strings.ReplaceAll(strings.ReplaceAll(destination, `"10"`, `"30"`), `"20"`, `"40"`),
		"p3":             strings.ReplaceAll(strings.ReplaceAll(destination, `"10"`, `""`), `"20"`, `"60"`),
		"other-region":   strings.Replace(destination, `"R"`, `"S"`, 1),
		"unlocated":      nil,
		"json-null":      `null`,
		"empty-location": `{}`,
		"":               destination,
	} {
		insertFlowProvider(t, s, id, location)
	}
	insert := func(provider string, location any, prompt, completion int, at time.Time) {
		t.Helper()
		_, err := s.pool.Exec(ctx, `INSERT INTO usage
 (provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens, created_at, request_location)
 VALUES ($1, 'flow-consumer', 'flow-model', $2, $3, $4, $5::jsonb)`, provider, prompt, completion, at, location)
		if err != nil {
			t.Fatal(err)
		}
	}
	for range 3 {
		insert("p1", origin, 10, 20, since.Add(time.Hour))
	}
	insert("p2", strings.ReplaceAll(strings.ReplaceAll(origin, `"10"`, `"30"`), `"20"`, `"40"`), 7, 9, since.Add(time.Hour))
	insert("p2", strings.ReplaceAll(strings.ReplaceAll(origin, `"10"`, `""`), `"20"`, `""`), 0, 1, since.Add(time.Hour))
	insert("p3", strings.ReplaceAll(strings.ReplaceAll(origin, `"10"`, `null`), `"20"`, `"50"`), 5, 6, since) // inclusive cutoff
	insert("p1", strings.Replace(origin, `"R"`, `"S"`, 1), 6, 7, since)
	insert("other-region", origin, 8, 9, since)
	insert("p1", `null`, 2, 3, since) // JSON null is located; SQL NULL is not.
	insert("p1", `{}`, 4, 5, since)
	insert("json-null", origin, 2, 3, since)
	insert("empty-location", origin, 4, 5, since)
	insert("", strings.Replace(origin, `"North"`, `"Empty provider ID"`, 1), 2, 3, since)
	insert("p1", `{"city":"Zero","latitude":0,"longitude":0}`, 1, 2, since)
	insert("p1", origin, 9999, 9999, since.Add(-time.Nanosecond))
	insert("p1", nil, 9999, 9999, since)
	insert("missing-provider", origin, 9999, 9999, since)
	insert("unlocated", origin, 9999, 9999, since)

	got := assertUsageFlowsMatchOriginal(t, s, since)
	if len(got) != 7 {
		t.Fatalf("got %d flow buckets, want 7", len(got))
	}
	main := got[0]
	if main.ConsumerCity != "North" || main.ProviderCity != "South" ||
		main.Requests != 6 || main.PromptTokens != 42 || main.CompletionTokens != 76 {
		t.Fatalf("weighted fixture totals: %+v", main)
	}
	if main.ConsumerLatitude != 15 || main.ConsumerLongitude != 30 ||
		main.ProviderLatitude != 18 || math.Abs(main.ProviderLongitude-100.0/3) > 1e-10 {
		t.Fatalf("weighted fixture coordinates: %+v", main)
	}
	if empty, err := s.UsageFlowBuckets(since.Add(2*time.Hour), nil); err != nil || len(empty) != 0 {
		t.Fatalf("empty window: buckets=%+v err=%v", empty, err)
	}
}

func TestUsageFlowBucketsTop50AfterCombiningProviders(t *testing.T) {
	s := testPostgresStore(t)
	since := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
	for _, id := range []string{"p1", "p2"} {
		insertFlowProvider(t, s, id, `{"city":"South","latitude":10,"longitude":20}`)
	}
	// Two providers per flow, with unequal counts. Limiting provider groups
	// before combining flows would lose contributors or choose the wrong top 50.
	_, err := s.pool.Exec(context.Background(), `INSERT INTO usage
 (provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens, created_at, request_location)
 SELECT CASE WHEN sample=1 THEN 'p1' ELSE 'p2' END, 'flow-consumer', 'flow-model', 2, 3, $1,
        jsonb_build_object('city', 'Origin ' || flow, 'latitude', sample, 'longitude', sample*2)
 FROM generate_series(1,60) AS flow
 CROSS JOIN LATERAL generate_series(1,flow+1) AS sample`, since)
	if err != nil {
		t.Fatal(err)
	}
	got := assertUsageFlowsMatchOriginal(t, s, since)
	if len(got) != 50 || got[0].Requests != 61 || got[49].Requests != 12 {
		t.Fatalf("top 50 contract: %+v", got)
	}
}

func TestUsageFlowPlanChoiceDoesNotLeakToPool(t *testing.T) {
	s, tracer := testPostgresStoreWithTracer(t, func(cfg *pgxpool.Config) {
		cfg.MaxConns = 1
		cfg.ConnConfig.RuntimeParams["plan_cache_mode"] = "force_generic_plan"
	})
	tracer.reset()
	if _, err := s.UsageFlowBuckets(time.Now().Add(time.Hour), nil); err != nil {
		t.Fatal(err)
	}
	events := tracer.snapshot()
	assertAnalyticsTx(t, events, "WITH located_usage AS MATERIALIZED")
	custom := -1
	for i, event := range events {
		if event.sql == "SET LOCAL plan_cache_mode = force_custom_plan" {
			custom = i
		}
		if strings.Contains(event.sql, "WITH located_usage AS MATERIALIZED") &&
			(custom < 0 || events[custom].pid != event.pid) {
			t.Fatal("flow query did not select a custom plan on its transaction connection")
		}
	}
	var mode string
	if err := s.pool.QueryRow(context.Background(), "SHOW plan_cache_mode").Scan(&mode); err != nil {
		t.Fatal(err)
	}
	if mode != "force_generic_plan" {
		t.Fatalf("flow query leaked plan_cache_mode=%q into the pool", mode)
	}
}

func insertFlowProvider(t *testing.T, s *PostgresStore, id string, location any) {
	t.Helper()
	_, err := s.pool.Exec(context.Background(), `INSERT INTO providers (id, hardware, models, backend, location)
 VALUES ($1, '{}', '[]', 'mlx-swift', $2::jsonb)`, id, location)
	if err != nil {
		t.Fatal(err)
	}
}

func assertUsageFlowsMatchOriginal(t *testing.T, s *PostgresStore, since time.Time) []UsageFlowBucket {
	t.Helper()
	got, err := s.UsageFlowBuckets(since, nil)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := s.pool.Query(context.Background(), originalFlowAggregateSQL, since)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	key := func(b UsageFlowBucket) string {
		return strings.Join([]string{b.ConsumerCity, b.ConsumerRegion, b.ConsumerRegionCode,
			b.ConsumerCountry, b.ConsumerCountryCode, b.ProviderCity, b.ProviderRegion,
			b.ProviderRegionCode, b.ProviderCountry, b.ProviderCountryCode}, "\x00")
	}
	want := make(map[string]UsageFlowBucket)
	for rows.Next() {
		var b UsageFlowBucket
		if err := rows.Scan(&b.ConsumerCity, &b.ConsumerRegion, &b.ConsumerRegionCode,
			&b.ConsumerCountry, &b.ConsumerCountryCode, &b.ConsumerLatitude, &b.ConsumerLongitude,
			&b.ProviderCity, &b.ProviderRegion, &b.ProviderRegionCode, &b.ProviderCountry,
			&b.ProviderCountryCode, &b.ProviderLatitude, &b.ProviderLongitude,
			&b.Requests, &b.PromptTokens, &b.CompletionTokens); err != nil {
			t.Fatal(err)
		}
		want[key(b)] = b
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(got) != len(want) {
		t.Fatalf("flow count: got %d, want %d", len(got), len(want))
	}
	for i, b := range got {
		expected, ok := want[key(b)]
		if !ok {
			t.Fatalf("unexpected flow: %+v", b)
		}
		if math.Abs(b.ConsumerLatitude-expected.ConsumerLatitude) > 1e-10 ||
			math.Abs(b.ConsumerLongitude-expected.ConsumerLongitude) > 1e-10 ||
			math.Abs(b.ProviderLatitude-expected.ProviderLatitude) > 1e-10 ||
			math.Abs(b.ProviderLongitude-expected.ProviderLongitude) > 1e-10 {
			t.Fatalf("coordinates differ: got %+v, want %+v", b, expected)
		}
		b.ConsumerLatitude, b.ConsumerLongitude = expected.ConsumerLatitude, expected.ConsumerLongitude
		b.ProviderLatitude, b.ProviderLongitude = expected.ProviderLatitude, expected.ProviderLongitude
		if !reflect.DeepEqual(b, expected) {
			t.Fatalf("flow differs: got %+v, want %+v", b, expected)
		}
		if i > 0 && got[i-1].Requests < b.Requests {
			t.Fatal("flows are not sorted by descending request count")
		}
	}
	return got
}
