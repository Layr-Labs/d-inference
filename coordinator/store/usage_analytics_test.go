package store

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// analyticsFixture seeds two located providers and a mix of located /
// unlocated usage rows. Provider locations go through UpsertProvider so the
// Postgres flow JOIN (providers.location) and the memory fallback
// (providerRecords) see the same data.
func analyticsFixture(t *testing.T, s Store) (providerA, providerB string) {
	t.Helper()
	providerA = uniqueID("prov-sf")
	providerB = uniqueID("prov-nyc")
	sf := &ProviderLocation{City: "San Francisco", Region: "California", RegionCode: "CA", Country: "United States", CountryCode: "US", Latitude: 37.7749, Longitude: -122.4194}
	nyc := &ProviderLocation{City: "New York", Region: "New York", RegionCode: "NY", Country: "United States", CountryCode: "US", Latitude: 40.7128, Longitude: -74.0060}
	for id, loc := range map[string]*ProviderLocation{providerA: sf, providerB: nyc} {
		if err := s.UpsertProvider(context.Background(), ProviderRecord{ID: id, Hardware: json.RawMessage("{}"), Models: json.RawMessage("[]"), Backend: "mlx", Location: loc, LastSeen: time.Now()}); err != nil {
			t.Fatalf("UpsertProvider(%s): %v", id, err)
		}
	}
	for i := 0; i < 5; i++ {
		s.RecordUsageWithCostAndLocation(providerA, "consumer", "model", uniqueID("req"), 10, 20, 0, nyc)
	}
	for i := 0; i < 3; i++ {
		s.RecordUsageWithCostAndLocation(providerB, "consumer", "model", uniqueID("req"), 5, 7, 0, sf)
	}
	for i := 0; i < 2; i++ {
		s.RecordUsageWithCostAndLocation(providerA, "consumer", "model", uniqueID("req"), 1, 1, 0, nil)
	}
	return providerA, providerB
}

func sortAnalytics(a *UsageAnalytics) {
	sort.Slice(a.LocationBuckets, func(i, j int) bool {
		if a.LocationBuckets[i].Requests != a.LocationBuckets[j].Requests {
			return a.LocationBuckets[i].Requests > a.LocationBuckets[j].Requests
		}
		return a.LocationBuckets[i].City < a.LocationBuckets[j].City
	})
	sort.Slice(a.FlowBuckets, func(i, j int) bool {
		if a.FlowBuckets[i].Requests != a.FlowBuckets[j].Requests {
			return a.FlowBuckets[i].Requests > a.FlowBuckets[j].Requests
		}
		return a.FlowBuckets[i].ConsumerCity < a.FlowBuckets[j].ConsumerCity
	})
}

func nearly(a, b float64) bool { return math.Abs(a-b) < 1e-6 }

// Both backends return the same snapshot for the same rows: located
// buckets, total count (so unknown = total − located), and consumer→provider
// flows resolved through the persisted provider location.
func TestUsageAnalyticsSinceParity(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			analyticsFixture(t, s)
			got, err := s.UsageAnalyticsSince(context.Background(), time.Now().Add(-time.Hour), nil)
			if err != nil {
				t.Fatalf("UsageAnalyticsSince: %v", err)
			}
			sortAnalytics(&got)

			if got.TotalRequests != 10 {
				t.Fatalf("TotalRequests = %d, want 10", got.TotalRequests)
			}
			if len(got.LocationBuckets) != 2 {
				t.Fatalf("location buckets = %+v, want 2", got.LocationBuckets)
			}
			nycB, sfB := got.LocationBuckets[0], got.LocationBuckets[1]
			if nycB.City != "New York" || nycB.Requests != 5 || nycB.PromptTokens != 50 || nycB.CompletionTokens != 100 || nycB.Providers != 1 || !nearly(nycB.Latitude, 40.7128) {
				t.Fatalf("NYC bucket = %+v", nycB)
			}
			if sfB.City != "San Francisco" || sfB.Requests != 3 || sfB.PromptTokens != 15 || sfB.CompletionTokens != 21 || sfB.Providers != 1 || !nearly(sfB.Longitude, -122.4194) {
				t.Fatalf("SF bucket = %+v", sfB)
			}
			if len(got.FlowBuckets) != 2 {
				t.Fatalf("flow buckets = %+v, want 2", got.FlowBuckets)
			}
			f0, f1 := got.FlowBuckets[0], got.FlowBuckets[1]
			if f0.ConsumerCity != "New York" || f0.ProviderCity != "San Francisco" || f0.Requests != 5 || !nearly(f0.ProviderLatitude, 37.7749) {
				t.Fatalf("flow[0] = %+v", f0)
			}
			if f1.ConsumerCity != "San Francisco" || f1.ProviderCity != "New York" || f1.Requests != 3 || !nearly(f1.ConsumerLongitude, -122.4194) {
				t.Fatalf("flow[1] = %+v", f1)
			}

			// A window that starts in the future is empty on both backends.
			empty, err := s.UsageAnalyticsSince(context.Background(), time.Now().Add(time.Hour), nil)
			if err != nil {
				t.Fatalf("future window: %v", err)
			}
			if empty.TotalRequests != 0 || len(empty.LocationBuckets) != 0 || len(empty.FlowBuckets) != 0 {
				t.Fatalf("future window not empty: %+v", empty)
			}

			// The window must be bounded on both backends.
			if _, err := s.UsageAnalyticsSince(context.Background(), time.Time{}, nil); err == nil {
				t.Fatal("zero since accepted; the analytics window must be bounded")
			}
		})
	}
}

// --- Postgres-only: statement shape, work_mem scope, window predicate, failure ---

// sqlRecorder is a pgx tracer that records every statement's SQL in order.
type sqlRecorder struct {
	mu   sync.Mutex
	sqls []string
}

func (r *sqlRecorder) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	r.mu.Lock()
	r.sqls = append(r.sqls, data.SQL)
	r.mu.Unlock()
	return ctx
}

func (r *sqlRecorder) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func (r *sqlRecorder) snapshot() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.sqls...)
}

func (r *sqlRecorder) reset() {
	r.mu.Lock()
	r.sqls = nil
	r.mu.Unlock()
}

// recordedPostgresStore is tracedPostgresStore with a SQL-recording tracer.
func recordedPostgresStore(t *testing.T, rec *sqlRecorder) *PostgresStore {
	t.Helper()
	testPostgresStore(t)
	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	cfg.ConnConfig.Tracer = rec
	cfg.MaxConns = 4
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("NewWithConfig: %v", err)
	}
	t.Cleanup(pool.Close)
	return &PostgresStore{pool: pool, priceCache: make(map[string]cachedPrice)}
}

// One UsageAnalyticsSince call is exactly one read-only transaction: BEGIN,
// SET LOCAL work_mem, the three aggregations, COMMIT — and none of the
// statements carries the `$1 IS NULL OR` form. The raised work_mem is scoped
// to that transaction: a connection used afterwards still reports the server
// default.
func TestPostgresUsageAnalyticsStatementShape(t *testing.T) {
	rec := &sqlRecorder{}
	s := recordedPostgresStore(t, rec)
	analyticsFixture(t, s)
	rec.reset()

	if _, err := s.UsageAnalyticsSince(context.Background(), time.Now().Add(-time.Hour), nil); err != nil {
		t.Fatalf("UsageAnalyticsSince: %v", err)
	}
	sqls := rec.snapshot()
	if len(sqls) != 6 {
		t.Fatalf("statements = %d, want 6 (begin, set local, 3 aggregations, commit):\n%s", len(sqls), strings.Join(sqls, "\n---\n"))
	}
	lower := make([]string, len(sqls))
	for i, q := range sqls {
		lower[i] = strings.ToLower(q)
	}
	if !strings.HasPrefix(lower[0], "begin") || !strings.Contains(lower[0], "read only") {
		t.Fatalf("first statement = %q, want a read-only BEGIN", sqls[0])
	}
	if !strings.HasPrefix(lower[1], "set local work_mem") {
		t.Fatalf("second statement = %q, want SET LOCAL work_mem", sqls[1])
	}
	for i := 2; i < 5; i++ {
		if !strings.Contains(lower[i], "from usage") || !strings.Contains(lower[i], "created_at >= $1") {
			t.Fatalf("statement %d = %q, want a bounded usage aggregation", i, sqls[i])
		}
		if strings.Contains(lower[i], "is null or") {
			t.Fatalf("statement %d still uses the nullable-OR predicate: %q", i, sqls[i])
		}
	}
	if !strings.HasPrefix(lower[5], "commit") {
		t.Fatalf("last statement = %q, want COMMIT", sqls[5])
	}

	var workMem string
	if err := s.pool.QueryRow(context.Background(), "SHOW work_mem").Scan(&workMem); err != nil {
		t.Fatalf("SHOW work_mem: %v", err)
	}
	if strings.EqualFold(workMem, usageAnalyticsWorkMem) {
		t.Fatalf("work_mem leaked out of the analytics transaction: %s", workMem)
	}
}

// The plain `created_at >= $1` predicate bounds the window: rows older than
// the cutoff are excluded from every view.
func TestPostgresUsageAnalyticsWindowPredicate(t *testing.T) {
	s := testPostgresStore(t)
	providerA, _ := analyticsFixture(t, s)
	// Backdate every row of the located NYC-consumer group (all 5 are
	// providerA + located) to two hours ago.
	if _, err := s.pool.Exec(context.Background(),
		`UPDATE usage SET created_at = now() - interval '2 hours'
		  WHERE provider_id = $1 AND request_location IS NOT NULL`, providerA); err != nil {
		t.Fatalf("backdate: %v", err)
	}
	got, err := s.UsageAnalyticsSince(context.Background(), time.Now().Add(-time.Hour), nil)
	if err != nil {
		t.Fatalf("UsageAnalyticsSince: %v", err)
	}
	if got.TotalRequests != 5 { // 3 located SF + 2 unlocated
		t.Fatalf("TotalRequests = %d, want 5", got.TotalRequests)
	}
	if len(got.LocationBuckets) != 1 || got.LocationBuckets[0].City != "San Francisco" || got.LocationBuckets[0].Requests != 3 {
		t.Fatalf("location buckets = %+v, want only the 3 SF rows", got.LocationBuckets)
	}
	if len(got.FlowBuckets) != 1 || got.FlowBuckets[0].Requests != 3 {
		t.Fatalf("flow buckets = %+v, want only the SF→NYC flow", got.FlowBuckets)
	}
}

// A failing database is reported as an error from both analytics entry
// points — never as an empty/zero result the caller could cache.
func TestPostgresAnalyticsReportFailure(t *testing.T) {
	s := testPostgresStore(t)
	s.pool.Close()
	if _, err := s.UsageAnalyticsSince(context.Background(), time.Now().Add(-time.Hour), nil); err == nil {
		t.Fatal("UsageAnalyticsSince on a closed pool returned no error")
	}
	if _, err := s.NetworkTotals(time.Time{}); err == nil {
		t.Fatal("NetworkTotals on a closed pool returned no error")
	}
	// A cancelled context is the timeout shape the refresher sees.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := s.UsageAnalyticsSince(ctx, time.Now().Add(-time.Hour), nil); !errors.Is(err, context.Canceled) && err == nil {
		t.Fatal("cancelled analytics context returned no error")
	}
}
