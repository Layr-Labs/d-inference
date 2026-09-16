package providerwriter

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestProviderWriteDeferredBuildsAtDequeue(t *testing.T) {
	var built atomic.Bool
	var handoffObserved atomic.Bool
	var writeBeforeHandoff atomic.Bool
	written := make(chan string, 1)
	w := &Writer{
		queue:   make(chan *writeRequest, 1),
		control: make(chan *writeRequest, 1),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
		writeFrameForTest: func(data []byte) error {
			if !handoffObserved.Load() {
				writeBeforeHandoff.Store(true)
			}
			written <- string(data)
			return nil
		},
	}
	metadataCh := make(chan TextFrameWriteMetadata, 1)
	errCh := make(chan error, 1)
	go func() {
		metadata, err := w.WriteDeferred(context.Background(), func(time.Time) ([]byte, error) {
			built.Store(true)
			return []byte(`{"built":"at-dequeue"}`), nil
		}, func(TextFrameWriteMetadata) {
			handoffObserved.Store(true)
		})
		metadataCh <- metadata
		errCh <- err
	}()
	deadline := time.Now().Add(time.Second)
	for len(w.queue) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("deferred request was not queued")
		}
		time.Sleep(time.Millisecond)
	}
	if built.Load() {
		t.Fatal("deferred frame built before writer dequeue")
	}

	go w.run()
	t.Cleanup(w.CloseNow)
	if err := <-errCh; err != nil {
		t.Fatalf("writeDeferred = %v", err)
	}
	if metadata := <-metadataCh; metadata.DequeuedAt.IsZero() {
		t.Fatal("successful deferred write returned zero dequeue metadata")
	}
	if got := <-written; got != `{"built":"at-dequeue"}` {
		t.Fatalf("written frame = %s", got)
	}
	if !built.Load() {
		t.Fatal("deferred builder was not called")
	}
	if writeBeforeHandoff.Load() {
		t.Fatal("socket write started before owner acknowledged dequeue metadata")
	}
}

func TestProviderWriteDeadlineAbortsInFlightSocketWrite(t *testing.T) {
	started := make(chan struct{})
	writeExited := make(chan struct{})
	stop := make(chan struct{})
	w := &Writer{
		queue:   make(chan *writeRequest, 1),
		control: make(chan *writeRequest, 1),
		stop:    stop,
		done:    make(chan struct{}),
		writeFrameForTest: func(data []byte) error {
			if string(data) == `{"type":"request"}` {
				close(started)
				<-stop
			}
			close(writeExited)
			return errStopped
		},
	}
	go w.run()
	t.Cleanup(w.CloseNow)

	ctx, cancel := context.WithCancel(context.Background())
	type result struct {
		metadata TextFrameWriteMetadata
		err      error
	}
	resultCh := make(chan result, 1)
	go func() {
		metadata, err := w.WriteDeferred(ctx, func(time.Time) ([]byte, error) {
			return []byte(`{"type":"request"}`), nil
		}, nil)
		resultCh <- result{metadata: metadata, err: err}
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("socket write did not start")
	}
	cancel()
	select {
	case got := <-resultCh:
		if got.err != context.Canceled {
			t.Fatalf("canceled write error = %v, want context.Canceled", got.err)
		}
		if got.metadata.DequeuedAt.IsZero() {
			t.Fatal("canceled in-flight write lost dequeue metadata")
		}
	case <-time.After(time.Second):
		t.Fatal("deadline did not abort in-flight socket write")
	}
	select {
	case <-writeExited:
	case <-time.After(time.Second):
		t.Fatal("socket write did not exit after writer close")
	}
	if !w.dead.Load() {
		t.Fatal("writer remained reusable after an aborted partial frame")
	}
}

func TestProviderWriteCompletionWinsConcurrentContextCancellation(t *testing.T) {
	writeCompleted := make(chan struct{})
	releaseDone := make(chan struct{})
	var pauseOnce sync.Once
	w := &Writer{
		queue:   make(chan *writeRequest, 1),
		control: make(chan *writeRequest, 1),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
		writeFrameForTest: func([]byte) error {
			return nil
		},
		afterWriteCompleteForTest: func() {
			pauseOnce.Do(func() {
				close(writeCompleted)
				<-releaseDone
			})
		},
	}
	go w.run()
	t.Cleanup(w.CloseNow)

	ctx, cancel := context.WithCancel(context.Background())
	type result struct {
		metadata TextFrameWriteMetadata
		err      error
	}
	resultCh := make(chan result, 1)
	go func() {
		metadata, err := w.WriteDeferred(ctx, func(time.Time) ([]byte, error) {
			return []byte(`{"type":"request"}`), nil
		}, nil)
		resultCh <- result{metadata: metadata, err: err}
	}()

	<-writeCompleted
	cancel()
	got := <-resultCh
	if got.err != nil {
		t.Fatalf("completed write returned context cancellation: %v", got.err)
	}
	if got.metadata.DequeuedAt.IsZero() {
		t.Fatal("completed write lost dequeue metadata")
	}
	if w.dead.Load() {
		t.Fatal("completed write cancellation killed a healthy connection")
	}

	close(releaseDone)
	if err := w.WriteControl(context.Background(), []byte(`{"type":"barrier"}`)); err != nil {
		t.Fatalf("writer was not reusable after completed write: %v", err)
	}
}

func TestProviderWriteCompletionWinsConcurrentWriterStop(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := &writeRequest{done: make(chan error, 1)}
	req.state.Store(5)
	req.done <- nil

	if err := writeResultAfterWriterStop(ctx, req); err != nil {
		t.Fatalf("completed write was reclassified by writer stop: %v", err)
	}
}

func TestProviderWriteDeferredCancellationDuringBuilderHasNoHandoff(t *testing.T) {
	builderStarted := make(chan struct{})
	releaseBuilder := make(chan struct{})
	wrote := atomic.Bool{}
	w := &Writer{
		queue:   make(chan *writeRequest, 1),
		control: make(chan *writeRequest, 1),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
		writeFrameForTest: func(data []byte) error {
			if string(data) == `{"type":"expired"}` {
				wrote.Store(true)
			}
			return nil
		},
	}
	go w.run()
	t.Cleanup(w.CloseNow)

	ctx, cancel := context.WithCancel(context.Background())
	type result struct {
		metadata TextFrameWriteMetadata
		err      error
	}
	resultCh := make(chan result, 1)
	go func() {
		metadata, err := w.WriteDeferred(ctx, func(time.Time) ([]byte, error) {
			close(builderStarted)
			<-releaseBuilder
			return []byte(`{"type":"expired"}`), nil
		}, nil)
		resultCh <- result{metadata: metadata, err: err}
	}()

	select {
	case <-builderStarted:
	case <-time.After(time.Second):
		t.Fatal("deferred builder did not start")
	}
	cancel()

	select {
	case got := <-resultCh:
		if got.err != context.Canceled {
			t.Fatalf("write error = %v, want context.Canceled", got.err)
		}
		if !got.metadata.DequeuedAt.IsZero() {
			t.Fatalf("canceled builder reported handoff at %v", got.metadata.DequeuedAt)
		}
	case <-time.After(time.Second):
		t.Fatal("caller waited for canceled deferred builder")
	}
	close(releaseBuilder)
	if err := w.WriteControl(context.Background(), []byte(`{"type":"barrier"}`)); err != nil {
		t.Fatalf("writer barrier after canceled builder: %v", err)
	}
	if wrote.Load() {
		t.Fatal("frame reached socket after context expired during builder")
	}
}
