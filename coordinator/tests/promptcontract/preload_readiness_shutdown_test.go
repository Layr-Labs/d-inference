package promptcontract_test

import (
	"context"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

// heldPreloadClient holds the controller's call after the actual control
// transport has returned, before the controller sees the result.
type heldPreloadClient struct {
	preload.Client
	returned chan<- struct{}
	release  <-chan struct{}
	once     *sync.Once
}

func (c heldPreloadClient) Preload(ctx context.Context, contractIDs []string) (sidecar.PreloadReport, error) {
	report, err := c.Client.Preload(ctx, contractIDs)
	c.once.Do(func() { close(c.returned) })
	<-c.release
	return report, err
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
	f := newReadinessControllerFixture(t, func(ctx context.Context, _ int64, ids []string) sidecar.PreloadReport {
		close(entered)
		defer close(handlerDone)
		select {
		case <-ctx.Done():
			canceled.Store(true)
		case <-releaseHandler:
		}
		return readinessReport(ids, "")
	}, func(client preload.Client) preload.Client {
		return heldPreloadClient{Client: client, returned: returned, release: releaseReturn, once: new(sync.Once)}
	})
	// This fallback runs before the fixture's Close cleanup. Even a broken
	// controller cancellation must not strand the test's parent loop/transport.
	t.Cleanup(func() { cancelParent(); releaseClient(); close(releaseHandler) })
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
	// The canceled attempt's own completion released its in-flight ticket and
	// counted the failure. A closed controller then refuses even a new catalog
	// generation, which no retry backoff covers.
	f.provision(a)
	f.verified(a)
	f.controller.Reconcile(context.Background())
	if f.controller.Status().Failures != 1 || f.preloads.Load() != 1 || f.controller.ReadyFor(a) {
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
