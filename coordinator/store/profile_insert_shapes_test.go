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

// TestRecordRequestProfilesPaddedShapesLandExactRows: batches that fall
// between shapes (9, 17, 33, 65 rows) land exactly n rows on both backends —
// the padding duplicates are absorbed — across the 16 and 32 shapes.
func TestRecordRequestProfilesPaddedShapesLandExactRows(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			base := time.Now().UTC().Truncate(time.Microsecond)
			for _, n := range []int{9, 17, 33, 65} {
				prefix := uniqueID(fmt.Sprintf("pad%d", n))
				recs := make([]*RequestProfileRecord, 0, n)
				for i := 0; i < n; i++ {
					recs = append(recs, fullProfile(fmt.Sprintf("%s-%d", prefix, i), 0, base.Add(time.Duration(i)*time.Millisecond)))
				}
				if err := s.RecordRequestProfiles(recs); err != nil {
					t.Fatalf("RecordRequestProfiles(%d): %v", n, err)
				}
				got := 0
				for _, r := range s.RequestProfilesSince(time.Time{}) {
					if strings.HasPrefix(r.RequestID, prefix) {
						got++
					}
				}
				if got != n {
					t.Fatalf("batch of %d landed %d rows", n, got)
				}
			}
		})
	}
}

// insertShapeTracer records the row arity of every request_profiles INSERT.
type insertShapeTracer struct {
	mu     sync.Mutex
	shapes []int
}

func (c *insertShapeTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	if strings.HasPrefix(d.SQL, "INSERT INTO request_profiles") {
		// column list + one tuple per row + conflict target
		c.mu.Lock()
		c.shapes = append(c.shapes, strings.Count(d.SQL, "(")-2)
		c.mu.Unlock()
	}
	return ctx
}

func (c *insertShapeTracer) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

// TestPostgresRequestProfileBatchesUseIntermediateShapes: a 9-row batch ships
// as one 16-row INSERT (was 64), 17 -> 32 (was 64), 33 -> 64, 70 -> 64 + 8.
func TestPostgresRequestProfileBatchesUseIntermediateShapes(t *testing.T) {
	testPostgresStore(t)
	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	tracer := &insertShapeTracer{}
	cfg.ConnConfig.Tracer = tracer
	cfg.MaxConns = 2
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("NewWithConfig: %v", err)
	}
	t.Cleanup(pool.Close)
	s := &PostgresStore{pool: pool, priceCache: make(map[string]cachedPrice)}

	base := time.Now().UTC().Truncate(time.Microsecond)
	for _, tc := range []struct {
		n    int
		want []int
	}{{9, []int{16}}, {17, []int{32}}, {33, []int{64}}, {70, []int{64, 8}}} {
		prefix := uniqueID(fmt.Sprintf("shape%d", tc.n))
		recs := make([]*RequestProfileRecord, 0, tc.n)
		for i := 0; i < tc.n; i++ {
			recs = append(recs, fullProfile(fmt.Sprintf("%s-%d", prefix, i), 0, base))
		}
		tracer.mu.Lock()
		tracer.shapes = nil
		tracer.mu.Unlock()
		if err := s.RecordRequestProfiles(recs); err != nil {
			t.Fatalf("RecordRequestProfiles(%d): %v", tc.n, err)
		}
		tracer.mu.Lock()
		got := append([]int(nil), tracer.shapes...)
		tracer.mu.Unlock()
		if fmt.Sprint(got) != fmt.Sprint(tc.want) {
			t.Fatalf("batch of %d shipped shapes %v, want %v", tc.n, got, tc.want)
		}
	}
}
