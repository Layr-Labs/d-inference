package liveness

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// fakeStore is a thin store.Store harness used to observe Writer behavior.
// It records AppendHeartbeats calls and can be configured to fail.
type fakeStore struct {
	store.Store // unused methods fall through to embedded nil — panics if hit

	mu     sync.Mutex
	calls  int
	rows   []store.HeartbeatEvent
	failN  int   // fail the next N calls then succeed
	delay  time.Duration
	failed atomic.Int64
}

func (f *fakeStore) AppendHeartbeats(ctx context.Context, events []store.HeartbeatEvent) error {
	f.mu.Lock()
	if f.failN > 0 {
		f.failN--
		f.failed.Add(1)
		f.mu.Unlock()
		return errors.New("simulated flush failure")
	}
	f.calls++
	f.rows = append(f.rows, events...)
	d := f.delay
	f.mu.Unlock()
	if d > 0 {
		select {
		case <-time.After(d):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

func (f *fakeStore) snapshot() (calls int, rows int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls, len(f.rows)
}

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
}

func newTestWriter(t *testing.T, fs *fakeStore, cfg Config) *Writer {
	t.Helper()
	w := NewWriter(fs, quietLogger(), nil, cfg)
	w.Start()
	t.Cleanup(w.Close)
	return w
}

// Writer accepts events from many goroutines and flushes them in batches.
func TestWriterFlushesBatches(t *testing.T) {
	fs := &fakeStore{}
	w := newTestWriter(t, fs, Config{
		BufferSize:    1024,
		BatchSize:     50,
		FlushInterval: 200 * time.Millisecond,
	})

	for i := 0; i < 120; i++ {
		w.Emit(store.HeartbeatEvent{ProviderID: "p", At: time.Now()})
	}

	// Wait long enough that a batch-size flush + at least one ticker flush
	// have had a chance to run.
	if !waitFor(func() bool {
		_, rows := fs.snapshot()
		return rows >= 120
	}, 2*time.Second) {
		_, rows := fs.snapshot()
		t.Fatalf("expected 120 rows persisted, got %d", rows)
	}
	if w.Stats().Dropped != 0 {
		t.Fatalf("expected 0 dropped, got %d", w.Stats().Dropped)
	}
}

// Bounded channel + non-blocking send: when the buffer is full Emit must
// return immediately and the drop counter must advance.
func TestWriterDropsWhenBufferFull(t *testing.T) {
	// Use a slow store so the flush goroutine can't keep up.
	fs := &fakeStore{delay: 50 * time.Millisecond}
	// Tiny buffer + large batch keeps the channel saturated.
	w := newTestWriter(t, fs, Config{
		BufferSize:    4,
		BatchSize:     4,
		FlushInterval: 500 * time.Millisecond,
	})

	// Emit far more than the buffer can hold; Emit must NEVER block.
	deadline := time.Now().Add(50 * time.Millisecond)
	for time.Now().Before(deadline) {
		w.Emit(store.HeartbeatEvent{ProviderID: "p", At: time.Now()})
	}

	if w.Stats().Dropped == 0 {
		t.Fatalf("expected at least one drop under saturation; stats=%+v", w.Stats())
	}
}

// On flush error, the writer should bump flush_failed and NOT lose the batch
// permanently. The next successful flush should persist the same rows.
func TestWriterRetainsBatchOnFlushError(t *testing.T) {
	fs := &fakeStore{failN: 1}
	w := newTestWriter(t, fs, Config{
		BufferSize:    16,
		BatchSize:     3,
		FlushInterval: 100 * time.Millisecond,
	})

	for i := 0; i < 3; i++ {
		w.Emit(store.HeartbeatEvent{ProviderID: "p"})
	}

	// Wait for at least one failed flush + one successful retry. The error
	// backoff is 2 ticks (200ms), so allow ~1s headroom.
	if !waitFor(func() bool {
		_, rows := fs.snapshot()
		return rows == 3 && w.Stats().FlushFailed > 0
	}, 2*time.Second) {
		_, rows := fs.snapshot()
		t.Fatalf("expected 3 rows + ≥1 failed flush; rows=%d stats=%+v", rows, w.Stats())
	}
}

// Close drains the buffer before returning (within DrainTimeout).
func TestWriterDrainsOnClose(t *testing.T) {
	fs := &fakeStore{}
	w := NewWriter(fs, quietLogger(), nil, Config{
		BufferSize:    32,
		BatchSize:     32,
		FlushInterval: 10 * time.Second, // never tick during the test
		DrainTimeout:  2 * time.Second,
	})
	w.Start()

	for i := 0; i < 10; i++ {
		w.Emit(store.HeartbeatEvent{ProviderID: "p"})
	}

	w.Close()

	_, rows := fs.snapshot()
	if rows != 10 {
		t.Fatalf("expected 10 rows persisted after Close, got %d", rows)
	}
}

// CounterFn callback is invoked on drops and on successful flushes so metrics
// wiring observes the right names + values.
func TestWriterPublishesCounters(t *testing.T) {
	type counterCall struct {
		name  string
		value int64
	}
	var (
		mu    sync.Mutex
		calls []counterCall
	)
	count := func(name string, value int64) {
		mu.Lock()
		defer mu.Unlock()
		calls = append(calls, counterCall{name, value})
	}

	// Slow store + tiny buffer to force at least one drop.
	fs := &fakeStore{delay: 30 * time.Millisecond}
	w := NewWriter(fs, quietLogger(), count, Config{
		BufferSize:    2,
		BatchSize:     2,
		FlushInterval: 200 * time.Millisecond,
	})
	w.Start()
	t.Cleanup(w.Close)

	for i := 0; i < 50; i++ {
		w.Emit(store.HeartbeatEvent{ProviderID: "p"})
	}

	// Wait until both kinds of counter have been seen.
	saw := func() (drop, flush bool) {
		mu.Lock()
		defer mu.Unlock()
		for _, c := range calls {
			switch c.name {
			case "liveness_dropped_total":
				drop = true
			case "liveness_flush_rows_total":
				flush = true
			}
		}
		return
	}
	if !waitFor(func() bool {
		d, f := saw()
		return d && f
	}, 2*time.Second) {
		d, f := saw()
		t.Fatalf("expected both counter kinds; drop=%v flush=%v calls=%v", d, f, calls)
	}
}

func waitFor(predicate func() bool, deadline time.Duration) bool {
	end := time.Now().Add(deadline)
	for time.Now().Before(end) {
		if predicate() {
			return true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return predicate()
}
