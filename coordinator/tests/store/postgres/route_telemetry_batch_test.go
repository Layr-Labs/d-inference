package postgres_test

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	routesql "github.com/eigeninference/d-inference/coordinator/internal/store/routesql"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestSplitInferenceRouteBatches(t *testing.T) {
	rec := func(id string, attempt int) *store.InferenceRouteRecord {
		return &store.InferenceRouteRecord{RequestID: id, Attempt: attempt}
	}

	t.Run("empty and nil-only input yields no batches", func(t *testing.T) {
		if got := routesql.SplitBatches(nil, 10); len(got) != 0 {
			t.Fatalf("nil input: got %d batches", len(got))
		}
		if got := routesql.SplitBatches([]*store.InferenceRouteRecord{nil, nil}, 10); len(got) != 0 {
			t.Fatalf("nil-only input: got %d batches", len(got))
		}
	})

	t.Run("duplicate key starts a new batch, order preserved", func(t *testing.T) {
		in := []*store.InferenceRouteRecord{rec("a", 1), rec("b", 1), nil, rec("a", 1), rec("c", 1), rec("a", 2)}
		got := routesql.SplitBatches(in, 0)
		if len(got) != 2 {
			t.Fatalf("batches = %d, want 2: %+v", len(got), got)
		}
		if len(got[0]) != 2 || got[0][0].RequestID != "a" || got[0][1].RequestID != "b" {
			t.Fatalf("batch 0 = %+v", got[0])
		}
		// (a,2) is a different key from (a,1) and stays in the second batch.
		if len(got[1]) != 3 || got[1][0].RequestID != "a" || got[1][1].RequestID != "c" || got[1][2].Attempt != 2 {
			t.Fatalf("batch 1 = %+v", got[1])
		}
	})

	t.Run("maxRows chunks without reordering", func(t *testing.T) {
		var in []*store.InferenceRouteRecord
		for i := 0; i < 7; i++ {
			in = append(in, rec(fmt.Sprintf("r%d", i), 1))
		}
		got := routesql.SplitBatches(in, 3)
		if len(got) != 3 || len(got[0]) != 3 || len(got[1]) != 3 || len(got[2]) != 1 {
			t.Fatalf("chunk sizes wrong: %d batches", len(got))
		}
		if got[2][0].RequestID != "r6" {
			t.Fatalf("last chunk = %+v", got[2])
		}
	})
}

func TestInferenceRouteInsertSQLShape(t *testing.T) {
	// The column list and the per-row parameter count must agree, or the
	// multi-row VALUES tuples would be misaligned with the columns.
	if n := len(strings.Split(routesql.InsertColumns, ",")); n != routesql.InsertParamCount {
		t.Fatalf("column list has %d entries, inferenceRouteInsertParamCount = %d", n, routesql.InsertParamCount)
	}

	one := routesql.InsertSQL(1)
	if !strings.Contains(one, "$57)") || strings.Contains(one, "$58") {
		t.Fatalf("single-row statement must end its tuple at $57: %s", one)
	}
	if !strings.Contains(one, "ON CONFLICT (request_id, attempt) DO UPDATE SET") {
		t.Fatalf("single-row statement lost the upsert clause")
	}
	if !strings.Contains(one, routesql.ErrorReasonUpsertAssignment) {
		t.Fatalf("upsert must keep the qualified error_reason assignment")
	}

	three := routesql.InsertSQL(3)
	if strings.Count(three, "VALUES (") != 1 || strings.Count(three, "($") != 3 {
		t.Fatalf("three-row statement must have exactly three tuples: %s", three)
	}
	if !strings.Contains(three, "$171)") || strings.Contains(three, "$172") {
		t.Fatalf("three-row statement must end at $171: %s", three)
	}
	if got := len(routesql.InsertArgs(nil, &store.InferenceRouteRecord{}, time.Now())); got != routesql.InsertParamCount {
		t.Fatalf("inferenceRouteInsertArgs produced %d args, want %d", got, routesql.InsertParamCount)
	}
	if got := len(routesql.OutcomeUpdateArgs("r", 1, &store.InferenceRouteOutcome{})); got != 24 {
		t.Fatalf("inferenceRouteOutcomeUpdateArgs produced %d args, want 24 ($1..$24)", got)
	}
}

// TestInferenceRouteBatchChunking writes more rows than fit in one statement
// so the chunk boundary is exercised on both backends, with a duplicate key
// straddling the boundary.
func TestInferenceRouteBatchChunking(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			prefix := uniqueID("chunk")
			n := routesql.MaxInsertRows + 40
			records := make([]*store.InferenceRouteRecord, 0, n+1)
			for i := 0; i < n; i++ {
				records = append(records, &store.InferenceRouteRecord{RequestID: fmt.Sprintf("%s-%d", prefix, i), Attempt: 1, Outcome: "selected", ProviderID: "p"})
			}
			// Re-record row 0 at the very end: lands in the last chunk and must
			// win over the first chunk's write.
			records = append(records, &store.InferenceRouteRecord{RequestID: fmt.Sprintf("%s-%d", prefix, 0), Attempt: 1, Outcome: "selected", ProviderID: "p-last"})
			if err := s.RecordInferenceRoutes(records); err != nil {
				t.Fatalf("RecordInferenceRoutes(%d): %v", len(records), err)
			}
			updates := make([]store.InferenceRouteOutcomeUpdate, 0, n)
			for i := 0; i < n; i++ {
				updates = append(updates, store.InferenceRouteOutcomeUpdate{RequestID: fmt.Sprintf("%s-%d", prefix, i), Attempt: 1, Outcome: &store.InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: i + 1}})
			}
			if err := s.UpdateInferenceRouteOutcomes(updates); err != nil {
				t.Fatalf("UpdateInferenceRouteOutcomes(%d): %v", len(updates), err)
			}
			got := 0
			for _, r := range s.InferenceRouteRecordsSince(time.Time{}) {
				if !strings.HasPrefix(r.RequestID, prefix) {
					continue
				}
				got++
				if r.FinalStatus != "success" || r.CompletionTokens == 0 {
					t.Fatalf("row %s missing its outcome: %+v", r.RequestID, r)
				}
				if r.RequestID == fmt.Sprintf("%s-%d", prefix, 0) && r.ProviderID != "p-last" {
					t.Fatalf("re-record across chunks must win: %+v", r)
				}
			}
			if got != n {
				t.Fatalf("rows = %d, want %d", got, n)
			}
		})
	}
}

// statementCounter is a pgx tracer that counts round trips: one TraceQueryStart
// per Exec/Query statement and one TraceBatchStart per SendBatch pipeline.
type statementCounter struct {
	mu           sync.Mutex
	queries      int
	batches      int
	batchQueries int
}

func (c *statementCounter) reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.queries, c.batches, c.batchQueries = 0, 0, 0
}

func (c *statementCounter) snapshot() (queries, batches, batchQueries int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.queries, c.batches, c.batchQueries
}

func (c *statementCounter) TraceQueryStart(ctx context.Context, _ *pgx.Conn, _ pgx.TraceQueryStartData) context.Context {
	c.mu.Lock()
	c.queries++
	c.mu.Unlock()
	return ctx
}

func (c *statementCounter) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

func (c *statementCounter) TraceBatchStart(ctx context.Context, _ *pgx.Conn, _ pgx.TraceBatchStartData) context.Context {
	c.mu.Lock()
	c.batches++
	c.mu.Unlock()
	return ctx
}

func (c *statementCounter) TraceBatchQuery(_ context.Context, _ *pgx.Conn, _ pgx.TraceBatchQueryData) {
	c.mu.Lock()
	c.batchQueries++
	c.mu.Unlock()
}

func (c *statementCounter) TraceBatchEnd(context.Context, *pgx.Conn, pgx.TraceBatchEndData) {}

// tracedPostgresStore returns a postgresFixture whose pool reports every
// statement to counter. The schema is migrated (and truncated) by the regular
// harness first, so this store only issues the writes under test.
func tracedPostgresStore(t *testing.T, counter *statementCounter) *postgresFixture {
	t.Helper()
	testPostgresStore(t)

	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	cfg.ConnConfig.Tracer = counter
	cfg.MaxConns = 4
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("NewWithConfig: %v", err)
	}
	t.Cleanup(pool.Close)
	return bindPostgresFixture(pool)
}

// TestPostgresInferenceRouteBatchStatementCount is the measured effect of the
// batch paths: N single-row writes cost N statements; the same N rows through
// the batch methods cost ONE multi-row INSERT and ONE pipelined batch.
func TestPostgresInferenceRouteBatchStatementCount(t *testing.T) {
	counter := &statementCounter{}
	s := tracedPostgresStore(t, counter)
	const n = 50
	prefix := uniqueID("count")
	rec := func(tag string, i int) *store.InferenceRouteRecord {
		return &store.InferenceRouteRecord{RequestID: fmt.Sprintf("%s-%s-%d", prefix, tag, i), Attempt: 1, ProviderID: "p", Outcome: "selected", Model: "m"}
	}
	upd := func(tag string, i int) store.InferenceRouteOutcomeUpdate {
		return store.InferenceRouteOutcomeUpdate{RequestID: fmt.Sprintf("%s-%s-%d", prefix, tag, i), Attempt: 1, Outcome: &store.InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: 3, CompletionTokensSet: true}}
	}

	// Before: one statement per record / per update.
	counter.reset()
	for i := 0; i < n; i++ {
		if err := s.RecordInferenceRoute(rec("single", i)); err != nil {
			t.Fatalf("RecordInferenceRoute: %v", err)
		}
	}
	for i := 0; i < n; i++ {
		if err := s.UpdateInferenceRouteOutcome(fmt.Sprintf("%s-single-%d", prefix, i), 1, upd("single", i).Outcome); err != nil {
			t.Fatalf("UpdateInferenceRouteOutcome: %v", err)
		}
	}
	if q, b, _ := counter.snapshot(); q != 2*n || b != 0 {
		t.Fatalf("single-row path: queries=%d batches=%d, want %d/0", q, b, 2*n)
	}

	// After: one multi-row INSERT for all records, one pipeline for all updates.
	records := make([]*store.InferenceRouteRecord, 0, n)
	updates := make([]store.InferenceRouteOutcomeUpdate, 0, n)
	for i := 0; i < n; i++ {
		records = append(records, rec("batch", i))
		updates = append(updates, upd("batch", i))
	}
	counter.reset()
	if err := s.RecordInferenceRoutes(records); err != nil {
		t.Fatalf("RecordInferenceRoutes: %v", err)
	}
	if q, b, _ := counter.snapshot(); q != 1 || b != 0 {
		t.Fatalf("batch insert: queries=%d batches=%d, want 1/0", q, b)
	}
	counter.reset()
	if err := s.UpdateInferenceRouteOutcomes(updates); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcomes: %v", err)
	}
	if q, b, bq := counter.snapshot(); q != 0 || b != 1 || bq != n {
		t.Fatalf("batch update: queries=%d batches=%d batchQueries=%d, want 0/1/%d", q, b, bq, n)
	}

	// Both populations read back identically.
	single, batch := 0, 0
	for _, r := range s.InferenceRouteRecordsSince(time.Time{}) {
		if !strings.HasPrefix(r.RequestID, prefix) || r.FinalStatus != "success" || r.CompletionTokens != 3 {
			continue
		}
		if strings.Contains(r.RequestID, "-single-") {
			single++
		} else {
			batch++
		}
	}
	if single != n || batch != n {
		t.Fatalf("rows with outcome: single=%d batch=%d, want %d/%d", single, batch, n, n)
	}
}

// TestPostgresInferenceRouteBatchDuplicateKeysSplit proves the store splits a
// batch at a repeated (request_id, attempt) instead of tripping PostgreSQL's
// "ON CONFLICT DO UPDATE command cannot affect row a second time".
func TestPostgresInferenceRouteBatchDuplicateKeysSplit(t *testing.T) {
	counter := &statementCounter{}
	s := tracedPostgresStore(t, counter)
	id := uniqueID("dup")
	counter.reset()
	err := s.RecordInferenceRoutes([]*store.InferenceRouteRecord{
		{RequestID: id, Attempt: 1, Outcome: "queued"},
		{RequestID: id, Attempt: 1, Outcome: "selected", ProviderID: "p"},
		{RequestID: id, Attempt: 1, Outcome: "selected", ProviderID: "p-final"},
	})
	if err != nil {
		t.Fatalf("RecordInferenceRoutes with duplicates: %v", err)
	}
	if q, _, _ := counter.snapshot(); q != 3 {
		t.Fatalf("three same-key records need three statements, got %d", q)
	}
	for _, r := range s.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == id {
			if r.ProviderID != "p-final" || r.Outcome != "selected" {
				t.Fatalf("last record must win: %+v", r)
			}
			return
		}
	}
	t.Fatal("row not found")
}
