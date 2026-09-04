package store

import (
	"context"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// sqlCounter is a pgx tracer that counts statements whose SQL contains a
// needle — here the model_prices SELECT — so the test measures exactly the
// round trips the price cache is meant to remove.
type sqlCounter struct {
	needle string
	mu     sync.Mutex
	n      int
}

func (c *sqlCounter) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}

func (c *sqlCounter) TraceQueryStart(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	if strings.Contains(d.SQL, c.needle) {
		c.mu.Lock()
		c.n++
		c.mu.Unlock()
	}
	return ctx
}

func (c *sqlCounter) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}

// pausingTracer is sqlCounter that also parks the FIRST model_prices SELECT
// at TraceQueryEnd — the row (or ErrNoRows) has been read, the cache has not
// been written — until release is closed; paused is closed when it parks.
// It injects the window in which a concurrent SetModelPrice commits and
// invalidates between a lookup's SELECT and its cache store.
type pausingTracer struct {
	sqlCounter
	paused  chan struct{}
	release chan struct{}
	once    sync.Once
}

type pausingTracerKey struct{}

func (p *pausingTracer) TraceQueryStart(ctx context.Context, conn *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	ctx = p.sqlCounter.TraceQueryStart(ctx, conn, d)
	if strings.Contains(d.SQL, p.needle) {
		ctx = context.WithValue(ctx, pausingTracerKey{}, true)
	}
	return ctx
}

func (p *pausingTracer) TraceQueryEnd(ctx context.Context, _ *pgx.Conn, _ pgx.TraceQueryEndData) {
	if ctx.Value(pausingTracerKey{}) == nil {
		return
	}
	p.once.Do(func() {
		close(p.paused)
		<-p.release
	})
}

// pricedPostgresStore returns a migrated PostgresStore whose pool reports the
// model_prices SELECT to counter. Skips without DATABASE_URL.
func pricedPostgresStore(t *testing.T, counter *sqlCounter) *PostgresStore {
	t.Helper()
	return pricedPostgresStoreTraced(t, counter)
}

// pricedPostgresStoreTraced is pricedPostgresStore with an arbitrary tracer.
func pricedPostgresStoreTraced(t *testing.T, tracer pgx.QueryTracer) *PostgresStore {
	t.Helper()
	testPostgresStore(t)
	cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	cfg.ConnConfig.Tracer = tracer
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

func (s *PostgresStore) priceCacheEntry(key string) (cachedPrice, bool) {
	s.priceCacheMu.RLock()
	defer s.priceCacheMu.RUnlock()
	e, ok := s.priceCache[key]
	return e, ok
}

func TestPostgresGetModelPriceCachesMisses(t *testing.T) {
	counter := &sqlCounter{needle: "FROM model_prices"}
	s := pricedPostgresStore(t, counter)
	account, model := uniqueID("acct"), uniqueID("model")

	// Two misses within the TTL: one statement. Before the negative cache
	// every miss was a round trip (the miss returned before populating).
	for i := 0; i < 2; i++ {
		if in, out, ok := s.GetModelPrice(account, model); ok || in != 0 || out != 0 {
			t.Fatalf("miss %d: GetModelPrice = (%d, %d, %v), want (0, 0, false)", i, in, out, ok)
		}
	}
	if got := counter.count(); got != 1 {
		t.Fatalf("model_prices statements after two misses = %d, want 1", got)
	}
	entry, ok := s.priceCacheEntry(account + ":" + model)
	if !ok || entry.found {
		t.Fatalf("negative entry = (%+v, %v), want a cached miss", entry, ok)
	}

	// SetModelPrice invalidates the negative entry: the next Get sees the row.
	if err := s.SetModelPrice(account, model, 700, 2100); err != nil {
		t.Fatalf("SetModelPrice: %v", err)
	}
	if in, out, ok := s.GetModelPrice(account, model); !ok || in != 700 || out != 2100 {
		t.Fatalf("after Set: GetModelPrice = (%d, %d, %v), want (700, 2100, true)", in, out, ok)
	}
	if got := counter.count(); got != 2 {
		t.Fatalf("model_prices statements after Set+Get = %d, want 2", got)
	}
	// The positive entry is served from memory too.
	if _, _, ok := s.GetModelPrice(account, model); !ok {
		t.Fatal("positive hit lost")
	}
	if got := counter.count(); got != 2 {
		t.Fatalf("positive hit issued a statement: %d", got)
	}
}

// TestPostgresGetModelPriceMissDoesNotOutliveConcurrentSet: a lookup reads
// "no row", and before it stores the miss a SetModelPrice commits the row
// and invalidates the key. The miss must NOT be cached afterwards — with the
// negative cache that would have billed the default price for priceCacheTTL
// against a custom row that exists — so the next lookup re-queries and sees
// the row. Before the generation check the stale miss was stored after the
// invalidation and the next Get answered (0, 0, false) from memory.
func TestPostgresGetModelPriceMissDoesNotOutliveConcurrentSet(t *testing.T) {
	tr := &pausingTracer{sqlCounter: sqlCounter{needle: "FROM model_prices"}, paused: make(chan struct{}), release: make(chan struct{})}
	s := pricedPostgresStoreTraced(t, tr)
	account, model := uniqueID("acct"), uniqueID("model")
	key := account + ":" + model

	type answer struct {
		in, out int64
		ok      bool
	}
	got := make(chan answer, 1)
	go func() {
		in, out, ok := s.GetModelPrice(account, model)
		got <- answer{in, out, ok}
	}()
	select {
	case <-tr.paused:
	case <-time.After(10 * time.Second):
		t.Fatal("the miss SELECT never reached the tracer pause")
	}
	// The lookup has read ErrNoRows and is parked before storing the miss.
	if err := s.SetModelPrice(account, model, 700, 2100); err != nil {
		t.Fatalf("SetModelPrice: %v", err)
	}
	close(tr.release)
	first := <-got
	if first.ok {
		t.Fatalf("in-flight lookup answered %+v; it read before the row committed and must report no row", first)
	}
	if e, cached := s.priceCacheEntry(key); cached && !e.found {
		t.Fatal("stale miss cached after a concurrent SetModelPrice invalidated the key")
	}
	if in, out, ok := s.GetModelPrice(account, model); !ok || in != 700 || out != 2100 {
		t.Fatalf("GetModelPrice after the concurrent Set = (%d, %d, %v), want (700, 2100, true)", in, out, ok)
	}
	if got := tr.count(); got != 2 {
		t.Fatalf("model_prices statements = %d, want 2 (the parked miss and one re-query)", got)
	}
}

// TestPostgresDeleteModelPriceInvalidatesCache: deleting a custom price
// drops its cached positive entry; the next lookup re-queries and answers
// no row. Before the change DeleteModelPrice invalidated nothing and the
// deleted price was billed from memory for up to priceCacheTTL.
func TestPostgresDeleteModelPriceInvalidatesCache(t *testing.T) {
	// The SELECT only: the DELETE's `DELETE FROM model_prices` must not count.
	counter := &sqlCounter{needle: "SELECT input_price, output_price FROM model_prices"}
	s := pricedPostgresStore(t, counter)
	account, model := uniqueID("acct"), uniqueID("model")
	if err := s.SetModelPrice(account, model, 700, 2100); err != nil {
		t.Fatalf("SetModelPrice: %v", err)
	}
	for i := 0; i < 2; i++ {
		if in, out, ok := s.GetModelPrice(account, model); !ok || in != 700 || out != 2100 {
			t.Fatalf("GetModelPrice = (%d, %d, %v), want (700, 2100, true)", in, out, ok)
		}
	}
	if got := counter.count(); got != 1 {
		t.Fatalf("statements after Set + two Gets = %d, want 1 (second served from memory)", got)
	}
	if err := s.DeleteModelPrice(account, model); err != nil {
		t.Fatalf("DeleteModelPrice: %v", err)
	}
	if in, out, ok := s.GetModelPrice(account, model); ok || in != 0 || out != 0 {
		t.Fatalf("GetModelPrice after Delete = (%d, %d, %v), want (0, 0, false)", in, out, ok)
	}
	if got := counter.count(); got != 2 {
		t.Fatalf("statements after Delete + Get = %d, want 2 (re-queried)", got)
	}
}

func TestPostgresGetModelPriceNegativeEntryExpires(t *testing.T) {
	counter := &sqlCounter{needle: "FROM model_prices"}
	s := pricedPostgresStore(t, counter)
	account, model := uniqueID("acct"), uniqueID("model")
	key := account + ":" + model

	s.GetModelPrice(account, model)
	if got := counter.count(); got != 1 {
		t.Fatalf("statements = %d, want 1", got)
	}
	// Age the entry past the TTL instead of sleeping.
	s.priceCacheMu.Lock()
	e := s.priceCache[key]
	e.at = e.at.Add(-priceCacheTTL - time.Second)
	s.priceCache[key] = e
	s.priceCacheMu.Unlock()

	s.GetModelPrice(account, model)
	if got := counter.count(); got != 2 {
		t.Fatalf("statements after TTL expiry = %d, want 2 (re-query)", got)
	}
}

func TestPostgresGetModelPriceDoesNotCacheErrors(t *testing.T) {
	counter := &sqlCounter{needle: "FROM model_prices"}
	s := pricedPostgresStore(t, counter)
	account, model := uniqueID("acct"), uniqueID("model")

	// A closed pool is a DB error, not "no row": it must answer (0,0,false)
	// without leaving an entry that would mask a real custom price for a TTL.
	s.pool.Close()
	if in, out, ok := s.GetModelPrice(account, model); ok || in != 0 || out != 0 {
		t.Fatalf("GetModelPrice on a closed pool = (%d, %d, %v), want (0, 0, false)", in, out, ok)
	}
	if _, cached := s.priceCacheEntry(account + ":" + model); cached {
		t.Fatal("a DB error was cached as a price miss")
	}
}

func TestPriceCacheBound(t *testing.T) {
	s := &PostgresStore{priceCache: make(map[string]cachedPrice)}
	for i := 0; i < priceCacheMaxEntries; i++ {
		s.storePriceCache(uniqueID("k"), cachedPrice{at: time.Now()}, 0)
	}
	if got := len(s.priceCache); got != priceCacheMaxEntries {
		t.Fatalf("len = %d, want %d", got, priceCacheMaxEntries)
	}
	s.storePriceCache("overflow", cachedPrice{at: time.Now()}, 0)
	if got := len(s.priceCache); got != 1 {
		t.Fatalf("len after overflow = %d, want 1 (reset)", got)
	}
}

// TestGetModelPriceMissThenSetParity pins the (0, 0, false) miss contract and
// the Set→Get visibility on both backends, so the negative cache cannot
// diverge the Postgres answer from the memory store's map lookup.
func TestGetModelPriceMissThenSetParity(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			account, model := uniqueID("acct"), uniqueID("model")
			for i := 0; i < 3; i++ {
				if in, out, ok := s.GetModelPrice(account, model); ok || in != 0 || out != 0 {
					t.Fatalf("miss %d = (%d, %d, %v), want (0, 0, false)", i, in, out, ok)
				}
			}
			if err := s.SetModelPrice(account, model, 11, 22); err != nil {
				t.Fatalf("SetModelPrice: %v", err)
			}
			if in, out, ok := s.GetModelPrice(account, model); !ok || in != 11 || out != 22 {
				t.Fatalf("after Set = (%d, %d, %v), want (11, 22, true)", in, out, ok)
			}
			// A different model under the same account is still a miss.
			if _, _, ok := s.GetModelPrice(account, uniqueID("other")); ok {
				t.Fatal("unrelated model reported a price")
			}
		})
	}
}
