package api

import (
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCompletionWorkersBoundConcurrencyAndDrain(t *testing.T) {
	pool := newCompletionWorkerPool(slog.New(slog.NewTextHandler(io.Discard, nil)), 4, 2)
	release := make(chan struct{})
	started := make(chan struct{}, 4)
	var active atomic.Int32
	var maximum atomic.Int32
	var completed atomic.Int32
	for range 4 {
		if !pool.submit(func() {
			current := active.Add(1)
			for {
				previous := maximum.Load()
				if current <= previous || maximum.CompareAndSwap(previous, current) {
					break
				}
			}
			started <- struct{}{}
			<-release
			active.Add(-1)
			completed.Add(1)
		}) {
			t.Fatal("submit rejected")
		}
	}
	<-started
	<-started
	if got := maximum.Load(); got != 2 {
		t.Fatalf("maximum active workers = %d, want 2", got)
	}

	close(release)
	pool.close()
	if got := completed.Load(); got != 4 {
		t.Fatalf("completed tasks = %d, want 4", got)
	}
	if pool.activeCount() != 0 || pool.depth() != 0 || pool.capacity() != 4 {
		t.Fatalf("pool state after close: active=%d depth=%d capacity=%d",
			pool.activeCount(), pool.depth(), pool.capacity())
	}
}

func TestCompletionWorkersBackpressureInsteadOfDropping(t *testing.T) {
	pool := newCompletionWorkerPool(nil, 1, 1)
	release := make(chan struct{})
	started := make(chan struct{})
	if !pool.submit(func() {
		close(started)
		<-release
	}) {
		t.Fatal("first submit rejected")
	}
	<-started
	if !pool.submit(func() {}) {
		t.Fatal("queued submit rejected")
	}

	submitted := make(chan bool, 1)
	go func() {
		submitted <- pool.submit(func() {})
	}()
	select {
	case <-submitted:
		t.Fatal("submit did not backpressure on a full queue")
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	select {
	case ok := <-submitted:
		if !ok {
			t.Fatal("backpressured task was dropped")
		}
	case <-time.After(time.Second):
		t.Fatal("backpressured submit did not resume")
	}
	pool.close()
}

func TestCompletionWorkerSurvivesPanickingTask(t *testing.T) {
	pool := newCompletionWorkerPool(nil, 2, 1)
	if !pool.submit(func() { panic("test panic") }) {
		t.Fatal("panic task rejected")
	}
	completed := make(chan struct{})
	if !pool.submit(func() { close(completed) }) {
		t.Fatal("follow-up task rejected")
	}
	select {
	case <-completed:
	case <-time.After(time.Second):
		t.Fatal("worker did not survive task panic")
	}
	pool.close()
}

func TestCompletionWorkersCloseIsIdempotent(t *testing.T) {
	pool := newCompletionWorkerPool(nil, 1, 1)
	var completed atomic.Int32
	var workers sync.WaitGroup
	workers.Add(1)
	if !pool.submit(func() {
		defer workers.Done()
		completed.Add(1)
	}) {
		t.Fatal("submit rejected")
	}
	pool.close()
	pool.close()
	workers.Wait()
	if completed.Load() != 1 {
		t.Fatalf("task executed %d times", completed.Load())
	}
	if pool.submit(func() {}) {
		t.Fatal("closed pool accepted work")
	}
}
