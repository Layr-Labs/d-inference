package promptcontract

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type readinessRoundTripFunc func(*http.Request) (*http.Response, error)

func (f readinessRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

// Exercise the public goroutine owner, not a direct reconcile call. The real
// transport must observe cancellation, but its return is deliberately held so
// Close cannot pass merely by canceling without joining the owned run loop.
func TestPreloadStartedControllerCloseCancelsAndDrains(t *testing.T) {
	entered, handlerDone, releaseHandler := make(chan struct{}), make(chan struct{}), make(chan struct{})
	parent, cancelParent := context.WithCancel(context.Background())
	returned, releaseReturn := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	releaseClient := func() { releaseOnce.Do(func() { close(releaseReturn) }) }
	var canceled atomic.Bool
	f := newReadinessControllerFixture(t, func(ctx context.Context, _ int64, ids []string) PreloadReport {
		close(entered)
		defer close(handlerDone)
		select {
		case <-ctx.Done():
			canceled.Store(true)
		case <-releaseHandler:
		}
		return readinessReport(ids, "")
	})
	// This fallback runs before the fixture's Close cleanup. Even a broken
	// controller cancellation must not strand the test's parent loop/transport.
	t.Cleanup(func() { cancelParent(); releaseClient(); close(releaseHandler) })
	transport := f.controller.client.controlHTTP.Transport
	f.controller.client.controlHTTP.Transport = readinessRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		response, err := transport.RoundTrip(request)
		close(returned)
		<-releaseReturn
		return response, err
	})
	a := strings.Repeat("a", 64)
	f.verified(a)
	f.controller.Start(parent)
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("public Start did not enter preload transport")
	}
	closed := make(chan struct{})
	go func() { f.controller.Close(); close(closed) }()
	select {
	case <-returned:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not cancel its real HTTP transport")
	}
	select {
	case <-closed:
		t.Fatal("Close returned before the owned request completed")
	case <-time.After(100 * time.Millisecond):
	}
	releaseClient()
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("Close did not join the owned run loop")
	}
	select {
	case <-handlerDone:
	case <-time.After(5 * time.Second):
		t.Fatal("HTTP handler did not observe cancellation")
	}
	if !canceled.Load() || f.preloads.Load() != 1 {
		t.Fatal("Close did not cancel the one in-flight preload")
	}
	f.controller.mu.RLock()
	inflight, stopped := f.controller.inflight, f.controller.closed
	f.controller.mu.RUnlock()
	if inflight != 0 || !stopped || f.controller.ReadyFor(a) {
		t.Fatal("Close returned with outstanding publication authority")
	}
	got := f.controller.Status()
	if got.Ready || got.Warm != 0 || got.Cold != 0 || got.Runs != 0 {
		t.Fatalf("canceled completion published readiness: %+v", got)
	}
	f.controller.Start(context.Background()) // A closed controller cannot restart.
	f.controller.Close()
	if f.preloads.Load() != 1 {
		t.Fatal("closed controller restarted transport")
	}
}
