package registry

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// Done is first consulted by the write result wait after successful submission.
// Observing it lets the fixture cancel an accepted queued write without exposing
// the writer's queues or relying on a sleep to infer enqueue completion.
type writerSubmissionContext struct {
	context.Context
	submitted chan struct{}
	notify    sync.Once
}

func (c *writerSubmissionContext) Done() <-chan struct{} {
	c.notify.Do(func() { close(c.submitted) })
	return c.Context.Done()
}

func fillProviderDataQueue(t *testing.T, p *Provider) {
	t.Helper()
	entered := make(chan struct{})
	resume := make(chan struct{})
	headDone := make(chan error, 1)
	release := sync.OnceFunc(func() { close(resume) })
	t.Cleanup(func() {
		release()
		p.closeWriterNow()
		select {
		case <-headDone:
		case <-time.After(2 * time.Second):
			t.Error("blocked writer did not stop during fixture cleanup")
		}
	})
	go func() {
		_, err := p.WriteTextDeferred(context.Background(), func(time.Time) ([]byte, error) {
			close(entered)
			<-resume
			return []byte(`{"type":"blocked-head"}`), nil
		}, nil)
		headDone <- err
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("writer did not enter the blocking builder")
	}
	for i := 0; i < 1024; i++ {
		ctx, cancel := context.WithCancel(context.Background())
		observed := &writerSubmissionContext{Context: ctx, submitted: make(chan struct{})}
		result := make(chan error, 1)
		go func() { result <- p.WriteText(observed, []byte(`{"type":"queued-canceled"}`)) }()
		select {
		case <-observed.submitted:
			cancel()
			select {
			case err := <-result:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("accepted queue fixture write = %v, want context.Canceled", err)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("accepted queue fixture write did not cancel")
			}
		case err := <-result:
			cancel()
			if !errors.Is(err, ErrProviderWriterQueueFull) {
				t.Fatalf("queue fixture rejection = %v, want ErrProviderWriterQueueFull", err)
			}
			return
		case <-time.After(2 * time.Second):
			cancel()
			t.Fatal("queue fixture write neither submitted nor rejected")
		}
	}
	t.Fatal("provider data queue did not reach its bound")
}
