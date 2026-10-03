package api

import (
	"testing"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
)

type countingFlusher struct{ n int }

func (f *countingFlusher) Flush() { f.n++ }

// deferredFlusher collapses any number of emitter flushes into one real flush
// and flushes nothing when nothing was written.
func TestDeferredFlusher(t *testing.T) {
	inner := &countingFlusher{}
	d := inresp.NewDeferredFlusher(inner)

	d.FlushNow()
	if inner.n != 0 {
		t.Fatalf("flushNow with nothing owed flushed %d times", inner.n)
	}
	for i := 0; i < 40; i++ {
		d.Flush()
	}
	d.FlushNow()
	d.FlushNow()
	if inner.n != 1 {
		t.Fatalf("40 deferred flushes should cost exactly 1 real flush, got %d", inner.n)
	}
	d.Flush()
	d.FlushNow()
	if inner.n != 2 {
		t.Fatalf("a new owed flush after flushNow should flush again, got %d", inner.n)
	}
}
