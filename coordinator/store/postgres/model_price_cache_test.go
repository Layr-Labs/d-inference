package postgres

import (
	"context"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type priceReadBarrierKey struct{}

// Delay one completed SQL read before GetModelPrice can publish its result.
// Updates run through the real pool while that old result is held back.
type priceReadBarrier struct {
	armed    atomic.Bool
	reads    atomic.Int64
	finished chan struct{}
	release  chan struct{}
}

func (b *priceReadBarrier) TraceQueryStart(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	if !strings.Contains(data.SQL, "SELECT input_price, output_price FROM model_prices") {
		return ctx
	}
	b.reads.Add(1)
	if b.armed.CompareAndSwap(true, false) {
		return context.WithValue(ctx, priceReadBarrierKey{}, true)
	}
	return ctx
}

func (b *priceReadBarrier) TraceQueryEnd(ctx context.Context, _ *pgx.Conn, data pgx.TraceQueryEndData) {
	if ctx.Value(priceReadBarrierKey{}) != true || data.Err != nil {
		return
	}
	close(b.finished)
	select {
	case <-b.release:
	case <-ctx.Done():
	}
}

func TestPostgresPriceMutationRejectsDelayedCacheFill(t *testing.T) {
	for _, mutation := range []string{"update", "delete"} {
		t.Run(mutation, func(t *testing.T) {
			// Use the regular isolated database harness for schema creation.
			testPostgresStore(t)
			barrier := &priceReadBarrier{finished: make(chan struct{}), release: make(chan struct{})}
			cfg, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
			if err != nil {
				t.Fatal(err)
			}
			cfg.ConnConfig.Tracer = barrier
			cfg.MaxConns = 2
			pool, err := pgxpool.NewWithConfig(t.Context(), cfg)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(pool.Close)
			s := &Store{pool: pool, priceCache: make(map[string]cachedPrice)}
			accountID, model := uniqueID("delayed-price"), "model"
			if err := s.SetModelPrice(accountID, model, 10, 20); err != nil {
				t.Fatal(err)
			}
			var releaseOnce sync.Once
			release := func() { releaseOnce.Do(func() { close(barrier.release) }) }
			t.Cleanup(release)
			type price struct {
				input, output int64
				found         bool
			}
			oldResult := make(chan price, 1)
			barrier.armed.Store(true)
			go func() {
				input, output, found := s.GetModelPrice(accountID, model)
				oldResult <- price{input, output, found}
			}()
			select {
			case <-barrier.finished:
			case <-time.After(5 * time.Second):
				t.Fatal("price read did not reach the publication barrier")
			}
			want := price{30, 40, true}
			if mutation == "delete" {
				err = s.DeleteModelPrice(accountID, model)
				want = price{}
			} else {
				err = s.SetModelPrice(accountID, model, want.input, want.output)
			}
			if err != nil {
				t.Fatal(err)
			}
			release()
			select {
			case got := <-oldResult:
				if got != (price{10, 20, true}) {
					t.Fatalf("in-flight read = %+v, want its already-read original value", got)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("in-flight price read did not finish")
			}
			// Every later lookup must reflect the completed local mutation.
			for range 2 {
				input, output, found := s.GetModelPrice(accountID, model)
				if got := (price{input, output, found}); got != want {
					t.Fatalf("later price = %+v, want %+v", got, want)
				}
			}
			wantReads := int64(2) // old read, then one fresh result reused from cache
			if mutation == "delete" {
				wantReads = 3 // absent rows remain uncached
			}
			if got := barrier.reads.Load(); got != wantReads {
				t.Fatalf("SQL price reads = %d, want %d", got, wantReads)
			}
		})
	}
}
