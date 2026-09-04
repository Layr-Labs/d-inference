package store

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// statementTracer records every statement pgx sends, with the backend PID it
// went to, so a test can assert which statements shared one transaction.
type statementTracer struct {
	mu     sync.Mutex
	events []tracedStatement
}

type tracedStatement struct {
	pid uint32
	sql string
}

func (t *statementTracer) TraceQueryStart(ctx context.Context, conn *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	t.mu.Lock()
	t.events = append(t.events, tracedStatement{pid: conn.PgConn().PID(), sql: data.SQL})
	t.mu.Unlock()
	return ctx
}

func (t *statementTracer) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func (t *statementTracer) reset() {
	t.mu.Lock()
	t.events = nil
	t.mu.Unlock()
}

func (t *statementTracer) snapshot() []tracedStatement {
	t.mu.Lock()
	defer t.mu.Unlock()
	return append([]tracedStatement(nil), t.events...)
}

// testPostgresStoreWithTracer is testPostgresStore with a statement tracer on
// every pooled connection. Only the tables this file touches are truncated.
func testPostgresStoreWithTracer(t *testing.T) (*PostgresStore, *statementTracer) {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	tracer := &statementTracer{}
	s, err := newPostgresWithPoolConfig(ctx, Config{DatabaseURL: dbURL}, func(cfg *pgxpool.Config) {
		cfg.ConnConfig.Tracer = tracer
	})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(s.Close)
	for _, table := range []string{"usage", "providers"} {
		if _, err := s.pool.Exec(ctx, "TRUNCATE "+table+" CASCADE"); err != nil {
			t.Fatalf("truncate %s: %v", table, err)
		}
	}
	return s, tracer
}

// assertAnalyticsTx checks that the statement containing marker ran inside a
// read-only transaction that first raised work_mem with SET LOCAL, all on one
// backend connection, and that the transaction was committed.
func assertAnalyticsTx(t *testing.T, events []tracedStatement, marker string) {
	t.Helper()
	sel := -1
	for i, e := range events {
		if strings.Contains(e.sql, marker) {
			sel = i
			break
		}
	}
	if sel < 0 {
		t.Fatalf("statement containing %q was not traced; traced: %v", marker, sqlOf(events))
	}
	pid := events[sel].pid
	var onConn []string
	for _, e := range events {
		if e.pid == pid {
			onConn = append(onConn, strings.ToLower(strings.Join(strings.Fields(e.sql), " ")))
		}
	}
	joined := strings.Join(onConn, " | ")
	setIdx := indexOf(onConn, "set local work_mem = '"+strings.ToLower(analyticsWorkMem)+"'")
	hashIdx := indexOf(onConn, "set local hash_mem_multiplier = 1.0")
	selIdx := indexOfContains(onConn, strings.ToLower(marker))
	beginIdx := indexOfContains(onConn, "begin")
	commitIdx := indexOf(onConn, "commit")
	if beginIdx < 0 || !strings.Contains(onConn[beginIdx], "read only") {
		t.Fatalf("%s: no read-only BEGIN on the statement's connection: %s", marker, joined)
	}
	if setIdx < 0 {
		t.Fatalf("%s: SET LOCAL work_mem = '%s' not executed on the statement's connection: %s", marker, analyticsWorkMem, joined)
	}
	if hashIdx < 0 || hashIdx < setIdx || hashIdx > selIdx {
		t.Fatalf("%s: SET LOCAL hash_mem_multiplier = 1.0 must run after work_mem and before the statement: %s", marker, joined)
	}
	if commitIdx < 0 {
		t.Fatalf("%s: transaction not committed: %s", marker, joined)
	}
	if !(beginIdx < setIdx && setIdx < selIdx && selIdx < commitIdx) {
		t.Fatalf("%s: statement order must be BEGIN < SET LOCAL < SELECT < COMMIT, got begin=%d set=%d select=%d commit=%d: %s",
			marker, beginIdx, setIdx, selIdx, commitIdx, joined)
	}
}

func sqlOf(events []tracedStatement) []string {
	out := make([]string, 0, len(events))
	for _, e := range events {
		out = append(out, e.sql)
	}
	return out
}

func indexOf(list []string, want string) int {
	for i, s := range list {
		if s == want {
			return i
		}
	}
	return -1
}

func indexOfContains(list []string, want string) int {
	for i, s := range list {
		if strings.Contains(s, want) {
			return i
		}
	}
	return -1
}

// TestUsageAnalyticsRunInWorkMemTransaction: the two /v1/stats analytics
// statements each run inside one read-only transaction that raises work_mem
// with SET LOCAL on the same connection first, return their rows, and leave
// the pool's session work_mem untouched afterwards.
func TestUsageAnalyticsRunInWorkMemTransaction(t *testing.T) {
	s, tracer := testPostgresStoreWithTracer(t)
	ctx := context.Background()

	loc := &ProviderLocation{
		City: "New York", Region: "New York", RegionCode: "NY",
		Country: "United States", CountryCode: "US",
		Latitude: 40.7128, Longitude: -74.0060, UpdatedAt: time.Now().UTC(),
	}
	providerLoc := &ProviderLocation{
		City: "San Francisco", Region: "California", RegionCode: "CA",
		Country: "United States", CountryCode: "US",
		Latitude: 37.7749, Longitude: -122.4194, UpdatedAt: time.Now().UTC(),
	}
	providerID := uniqueID("analytics-provider")
	if err := s.UpsertProvider(ctx, ProviderRecord{
		ID:       providerID,
		Hardware: json.RawMessage(`{}`),
		Models:   json.RawMessage(`[]`),
		Backend:  "mlx-swift",
		Location: providerLoc,
	}); err != nil {
		t.Fatalf("upsert provider: %v", err)
	}
	for i := 0; i < 3; i++ {
		s.RecordUsageWithCostAndLocation(providerID, "consumer", "model", uniqueID("req"), 10, 20, 0, loc)
	}
	since := time.Now().Add(-24 * time.Hour)

	tracer.reset()
	locations, err := s.UsageLocationBuckets(since)
	if err != nil {
		t.Fatal(err)
	}
	if len(locations) != 1 || locations[0].Requests != 3 || locations[0].Providers != 1 {
		t.Fatalf("location buckets = %+v, want one NY bucket with 3 requests from 1 provider", locations)
	}
	assertAnalyticsTx(t, tracer.snapshot(), "COUNT(DISTINCT provider_id)")

	tracer.reset()
	flows, err := s.UsageFlowBuckets(since, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(flows) != 1 || flows[0].Requests != 3 || flows[0].ProviderCity != "San Francisco" {
		t.Fatalf("flow buckets = %+v, want one NY->SF flow with 3 requests", flows)
	}
	assertAnalyticsTx(t, tracer.snapshot(), "JOIN providers p ON p.id = u.provider_id")

	tracer.reset()
	totals, err := s.NetworkTotals(since)
	if err != nil {
		t.Fatalf("network totals: %v", err)
	}
	if totals.Jobs != 0 || totals.ActiveAccounts != 0 {
		t.Fatalf("network totals on an empty earnings table = %+v, want zeros", totals)
	}
	assertAnalyticsTx(t, tracer.snapshot(), "AS active_accounts")

	// SET LOCAL must not leak past the transaction: every pooled session
	// still reports the server default.
	for i := 0; i < 5; i++ {
		var workMem string
		if err := s.pool.QueryRow(ctx, "SHOW work_mem").Scan(&workMem); err != nil {
			t.Fatalf("SHOW work_mem: %v", err)
		}
		if strings.EqualFold(workMem, analyticsWorkMem) {
			t.Fatalf("work_mem leaked outside the analytics transaction: session reports %s", workMem)
		}
	}

	// The window predicate is a real cutoff: rows older than since are excluded.
	if got, err := s.UsageLocationBuckets(time.Now().Add(time.Hour)); err != nil || len(got) != 0 {
		t.Fatalf("future cutoff returned %d buckets, want 0", len(got))
	}
}

// TestNetworkTotalsReturnsErrorWhenUnavailable: a store that cannot run the
// aggregate reports an error instead of a zero row (which callers used to
// cache and serve as data).
func TestNetworkTotalsReturnsErrorWhenUnavailable(t *testing.T) {
	s := testPostgresStore(t)
	s.Close()
	if _, err := s.NetworkTotals(time.Now().Add(-24 * time.Hour)); err == nil {
		t.Fatal("NetworkTotals on a closed pool returned no error")
	}
}

// TestUsageAggregatesReturnErrorWhenUnavailable: the four usage aggregates
// behind /v1/stats report an error instead of zero totals, a zero count or a
// nil series when the statement cannot run, so the stats refresher can keep
// its last good value instead of caching a corrupted body.
func TestUsageAggregatesReturnErrorWhenUnavailable(t *testing.T) {
	s := testPostgresStore(t)
	s.Close()
	if _, err := s.UsageLocationBuckets(time.Now()); err == nil {
		t.Error("UsageLocationBuckets on a closed pool returned no error")
	}
	if _, err := s.UsageFlowBuckets(time.Now(), nil); err == nil {
		t.Error("UsageFlowBuckets on a closed pool returned no error")
	}
	since := time.Now().Add(-24 * time.Hour)
	if _, err := s.UsageTotals(); err == nil {
		t.Error("UsageTotals on a closed pool returned no error")
	}
	if _, err := s.UsageTotalsSince(since); err == nil {
		t.Error("UsageTotalsSince on a closed pool returned no error")
	}
	if _, err := s.UsageCountSince(since); err == nil {
		t.Error("UsageCountSince on a closed pool returned no error")
	}
	if _, err := s.UsageTimeSeries(since, time.Now(), time.Minute); err == nil {
		t.Error("UsageTimeSeries on a closed pool returned no error")
	}
}
