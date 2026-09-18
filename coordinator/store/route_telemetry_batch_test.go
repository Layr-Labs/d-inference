package store

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// --- pure helpers ---

func TestSplitInferenceRouteBatches(t *testing.T) {
	rec := func(id string, attempt int) *InferenceRouteRecord {
		return &InferenceRouteRecord{RequestID: id, Attempt: attempt}
	}

	t.Run("empty and nil-only input yields no batches", func(t *testing.T) {
		if got := splitInferenceRouteBatches(nil, 10); len(got) != 0 {
			t.Fatalf("nil input: got %d batches", len(got))
		}
		if got := splitInferenceRouteBatches([]*InferenceRouteRecord{nil, nil}, 10); len(got) != 0 {
			t.Fatalf("nil-only input: got %d batches", len(got))
		}
	})

	t.Run("duplicate key starts a new batch, order preserved", func(t *testing.T) {
		in := []*InferenceRouteRecord{rec("a", 1), rec("b", 1), nil, rec("a", 1), rec("c", 1), rec("a", 2)}
		got := splitInferenceRouteBatches(in, 0)
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
		var in []*InferenceRouteRecord
		for i := 0; i < 7; i++ {
			in = append(in, rec(fmt.Sprintf("r%d", i), 1))
		}
		got := splitInferenceRouteBatches(in, 3)
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
	if n := len(strings.Split(inferenceRouteInsertColumns, ",")); n != inferenceRouteInsertParamCount {
		t.Fatalf("column list has %d entries, inferenceRouteInsertParamCount = %d", n, inferenceRouteInsertParamCount)
	}

	one := inferenceRouteInsertSQL(1)
	if !strings.Contains(one, "$57)") || strings.Contains(one, "$58") {
		t.Fatalf("single-row statement must end its tuple at $57: %s", one)
	}
	if !strings.Contains(one, "ON CONFLICT (request_id, attempt) DO UPDATE SET") {
		t.Fatalf("single-row statement lost the upsert clause")
	}
	if !strings.Contains(one, inferenceRouteErrorReasonUpsertAssignment) {
		t.Fatalf("upsert must keep the qualified error_reason assignment")
	}

	three := inferenceRouteInsertSQL(3)
	if strings.Count(three, "VALUES (") != 1 || strings.Count(three, "($") != 3 {
		t.Fatalf("three-row statement must have exactly three tuples: %s", three)
	}
	if !strings.Contains(three, "$171)") || strings.Contains(three, "$172") {
		t.Fatalf("three-row statement must end at $171: %s", three)
	}
	if got := len(inferenceRouteInsertArgs(nil, &InferenceRouteRecord{}, time.Now())); got != inferenceRouteInsertParamCount {
		t.Fatalf("inferenceRouteInsertArgs produced %d args, want %d", got, inferenceRouteInsertParamCount)
	}
	if got := len(inferenceRouteOutcomeUpdateArgs("r", 1, &InferenceRouteOutcome{})); got != 24 {
		t.Fatalf("inferenceRouteOutcomeUpdateArgs produced %d args, want 24 ($1..$24)", got)
	}
}

// --- both backends ---

func TestInferenceRouteBatch(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) { testInferenceRouteBatch(t, s) })
	}
}

func testInferenceRouteBatch(t *testing.T, s Store) {
	t.Helper()

	if err := s.RecordInferenceRoutes(nil); err != nil {
		t.Fatalf("RecordInferenceRoutes(nil): %v", err)
	}
	if err := s.RecordInferenceRoutes([]*InferenceRouteRecord{nil}); err != nil {
		t.Fatalf("RecordInferenceRoutes([nil]): %v", err)
	}
	if err := s.UpdateInferenceRouteOutcomes(nil); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcomes(nil): %v", err)
	}

	prefix := uniqueID("batch")
	id := func(i int) string { return fmt.Sprintf("%s-%d", prefix, i) }
	firstCreated := time.Now().Add(-time.Hour).UTC().Truncate(time.Microsecond)

	// One batch: four distinct keys, one re-record of key 1 (queued -> selected,
	// the live dispatch.go pattern) and a nil entry. The re-record must land
	// AFTER the first write (later record wins the snapshot) and must keep the
	// original created_at, exactly like sequential single-row upserts.
	records := []*InferenceRouteRecord{
		{RequestID: id(1), Attempt: 1, ProviderID: "", Outcome: "queued", Model: "m", CreatedAt: firstCreated, UpdatedAt: firstCreated},
		{RequestID: id(2), Attempt: 1, ProviderID: "p2", Outcome: "selected", Model: "m", CandidateCount: 2},
		nil,
		{RequestID: id(3), Attempt: 1, ProviderID: "p3", Outcome: "selected", Model: "m", ProviderRegion: "us-east"},
		{RequestID: id(1), Attempt: 1, ProviderID: "p1", Outcome: "selected", Model: "m", CandidateCount: 5},
		{RequestID: id(1), Attempt: 2, ProviderID: "p1b", Outcome: "selected", Model: "m"},
	}
	if err := s.RecordInferenceRoutes(records); err != nil {
		t.Fatalf("RecordInferenceRoutes: %v", err)
	}

	// One pipelined update batch, in order: a commit-style latency update, a
	// terminal on the same key (must merge on top, not replace), a terminal for
	// another key, a nil outcome (skipped), and an unknown key (no-op).
	updates := []InferenceRouteOutcomeUpdate{
		{RequestID: id(1), Attempt: 1, Outcome: &InferenceRouteOutcome{ActualTTFTMs: 42, UsedBackup: true}},
		{RequestID: id(1), Attempt: 1, Outcome: &InferenceRouteOutcome{FinalStatus: "error", ErrorCode: 502, ErrorClass: "provider_error", CompletionTokensSet: true}},
		{RequestID: id(1), Attempt: 1, Outcome: &InferenceRouteOutcome{FinalStatus: "partial_success"}},
		{RequestID: id(2), Attempt: 1, Outcome: &InferenceRouteOutcome{FinalStatus: "success", PromptTokens: 10, CompletionTokens: 20, CostMicroUSD: 7, CompletionTokensSet: true}},
		{RequestID: id(3), Attempt: 1, Outcome: nil},
		{RequestID: id(3) + "-missing", Attempt: 9, Outcome: &InferenceRouteOutcome{FinalStatus: "success"}},
	}
	if err := s.UpdateInferenceRouteOutcomes(updates); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcomes: %v", err)
	}

	byKey := map[string]InferenceRouteRecord{}
	for _, r := range s.InferenceRouteRecordsSince(time.Time{}) {
		if strings.HasPrefix(r.RequestID, prefix) {
			byKey[inferenceRouteKey(r.RequestID, r.Attempt)] = r
		}
	}
	if len(byKey) != 4 {
		t.Fatalf("rows = %d, want 4 (nil skipped, duplicate merged): %v", len(byKey), byKey)
	}

	r1 := byKey[inferenceRouteKey(id(1), 1)]
	if r1.ProviderID != "p1" || r1.Outcome != "selected" || r1.CandidateCount != 5 {
		t.Fatalf("re-recorded row must carry the LATER snapshot: %+v", r1)
	}
	if !r1.CreatedAt.Equal(firstCreated) {
		t.Fatalf("re-record must keep the first created_at: got %v want %v", r1.CreatedAt, firstCreated)
	}
	// Ordered merge: latency from update 1, error from update 2, final status
	// overridden by update 3 while error_code/class (zero in update 3) survive.
	if r1.FinalStatus != "partial_success" || r1.ErrorCode != 502 || r1.ErrorClass != "provider_error" || r1.ActualTTFTMs != 42 || !r1.UsedBackup {
		t.Fatalf("ordered outcome merge wrong: %+v", r1)
	}
	if r1.CompletionTokens != 0 {
		t.Fatalf("terminal error must persist completion_tokens 0: %+v", r1)
	}

	r2 := byKey[inferenceRouteKey(id(2), 1)]
	if r2.FinalStatus != "success" || r2.PromptTokens != 10 || r2.CompletionTokens != 20 || r2.CostMicroUSD != 7 || r2.CandidateCount != 2 {
		t.Fatalf("row 2 outcome/snapshot wrong: %+v", r2)
	}
	r3 := byKey[inferenceRouteKey(id(3), 1)]
	if r3.FinalStatus != "" || r3.ProviderRegion != "us-east" {
		t.Fatalf("row 3 must be untouched by the nil update: %+v", r3)
	}
	if r12 := byKey[inferenceRouteKey(id(1), 2)]; r12.ProviderID != "p1b" {
		t.Fatalf("attempt 2 must be its own row: %+v", r12)
	}

	// A single-row write after a batch behaves identically (same code path).
	if err := s.RecordInferenceRoute(&InferenceRouteRecord{RequestID: id(3), Attempt: 1, ProviderID: "p3-refresh", Outcome: "selected", Model: "m"}); err != nil {
		t.Fatalf("RecordInferenceRoute: %v", err)
	}
	if err := s.UpdateInferenceRouteOutcome(id(3), 1, &InferenceRouteOutcome{FinalStatus: "cancelled", CompletionTokensSet: true}); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome: %v", err)
	}
	for _, r := range s.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == id(3) && r.Attempt == 1 {
			if r.ProviderID != "p3-refresh" || r.FinalStatus != "cancelled" || r.ProviderRegion != "" {
				t.Fatalf("single-row refresh + update after batch wrong: %+v", r)
			}
		}
	}
}

// TestInferenceRouteBatchChunking writes more rows than fit in one statement
// so the chunk boundary is exercised on both backends, with a duplicate key
// straddling the boundary.
func TestInferenceRouteBatchChunking(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			prefix := uniqueID("chunk")
			n := maxInferenceRouteInsertRows + 40
			records := make([]*InferenceRouteRecord, 0, n+1)
			for i := 0; i < n; i++ {
				records = append(records, &InferenceRouteRecord{RequestID: fmt.Sprintf("%s-%d", prefix, i), Attempt: 1, Outcome: "selected", ProviderID: "p"})
			}
			// Re-record row 0 at the very end: lands in the last chunk and must
			// win over the first chunk's write.
			records = append(records, &InferenceRouteRecord{RequestID: fmt.Sprintf("%s-%d", prefix, 0), Attempt: 1, Outcome: "selected", ProviderID: "p-last"})
			if err := s.RecordInferenceRoutes(records); err != nil {
				t.Fatalf("RecordInferenceRoutes(%d): %v", len(records), err)
			}
			updates := make([]InferenceRouteOutcomeUpdate, 0, n)
			for i := 0; i < n; i++ {
				updates = append(updates, InferenceRouteOutcomeUpdate{RequestID: fmt.Sprintf("%s-%d", prefix, i), Attempt: 1, Outcome: &InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: i + 1}})
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

// --- postgres statement accounting ---

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

// tracedPostgresStore returns a PostgresStore whose pool reports every
// statement to counter. The schema is migrated (and truncated) by the regular
// harness first, so this store only issues the writes under test.
func tracedPostgresStore(t *testing.T, counter *statementCounter) *PostgresStore {
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
	return &PostgresStore{pool: pool, priceCache: make(map[string]cachedPrice)}
}

// TestPostgresInferenceRouteBatchStatementCount is the measured effect of the
// batch paths: N single-row writes cost N statements; the same N rows through
// the batch methods cost ONE multi-row INSERT and ONE pipelined batch.
func TestPostgresInferenceRouteBatchStatementCount(t *testing.T) {
	counter := &statementCounter{}
	s := tracedPostgresStore(t, counter)
	const n = 50
	prefix := uniqueID("count")
	rec := func(tag string, i int) *InferenceRouteRecord {
		return &InferenceRouteRecord{RequestID: fmt.Sprintf("%s-%s-%d", prefix, tag, i), Attempt: 1, ProviderID: "p", Outcome: "selected", Model: "m"}
	}
	upd := func(tag string, i int) InferenceRouteOutcomeUpdate {
		return InferenceRouteOutcomeUpdate{RequestID: fmt.Sprintf("%s-%s-%d", prefix, tag, i), Attempt: 1, Outcome: &InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: 3, CompletionTokensSet: true}}
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
	records := make([]*InferenceRouteRecord, 0, n)
	updates := make([]InferenceRouteOutcomeUpdate, 0, n)
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
	err := s.RecordInferenceRoutes([]*InferenceRouteRecord{
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
