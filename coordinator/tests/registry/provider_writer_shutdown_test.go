package registry_test

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
)

type closingWriterTransport struct {
	entered chan struct{}
	release chan struct{}
}

func (t *closingWriterTransport) Write([]byte) error { return nil }
func (t *closingWriterTransport) Close() {
	close(t.entered)
	<-t.release
}
func (t *closingWriterTransport) Watch(stop, writerStop <-chan struct{}) {
	select {
	case <-stop:
	case <-writerStop:
	}
}

type enqueuePreambleContext struct {
	context.Context
	entered chan struct{}
	release chan struct{}
}

func (c enqueuePreambleContext) Err() error {
	close(c.entered)
	<-c.release
	return nil
}

func TestProviderWriterEnqueueDoesNotWaitForTransportClose(t *testing.T) {
	transport := &closingWriterTransport{entered: make(chan struct{}), release: make(chan struct{})}
	w := providerwrite.New(transport, nil)
	go w.Run()
	closed := make(chan struct{})
	t.Cleanup(func() {
		close(transport.release)
		<-closed
		<-w.Done()
	})

	// Pause a real enqueue after its initial liveness check. Shutdown then
	// publishes stop while the transport waits for an already-running close.
	ctx := enqueuePreambleContext{Context: context.Background(), entered: make(chan struct{}), release: make(chan struct{})}
	enqueued := make(chan error, 1)
	go func() { enqueued <- w.Enqueue(ctx, []byte(`{"type":"model_autopilot_control"}`)) }()
	<-ctx.entered
	go func() { w.Close(); close(closed) }()
	<-transport.entered
	close(ctx.release)

	select {
	case err := <-enqueued:
		if !errors.Is(err, providerwrite.ErrStopped) {
			t.Fatalf("enqueue during transport close = %v, want stopped", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("enqueue held its caller behind transport close")
	}
	select {
	case <-closed:
		t.Fatal("test transport close completed before release")
	default:
	}
}

type inFlightClosingWriterTransport struct {
	closingWriterTransport
	writeStarted chan struct{}
	writeStopped chan struct{}
}

func (t *inFlightClosingWriterTransport) Write([]byte) error {
	close(t.writeStarted)
	<-t.writeStopped
	return providerwrite.ErrStopped
}

func (t *inFlightClosingWriterTransport) Close() {
	t.closingWriterTransport.Close()
	close(t.writeStopped)
}

func TestProviderWriterConcurrentClosePreservesCancellationFence(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		transport := &inFlightClosingWriterTransport{
			closingWriterTransport: closingWriterTransport{entered: make(chan struct{}), release: make(chan struct{})},
			writeStarted:           make(chan struct{}),
			writeStopped:           make(chan struct{}),
		}
		w := providerwrite.New(transport, nil)
		go w.Run()
		closed := make(chan struct{})
		defer func() {
			close(transport.release)
			<-closed
			<-w.Done()
		}()

		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		writeReturned := make(chan struct{})
		go func() {
			metadata, err := w.WriteDeferred(ctx, func(time.Time) ([]byte, error) { return []byte("inference"), nil }, nil)
			if !errors.Is(err, context.Canceled) || !metadata.Committed {
				t.Errorf("canceled in-flight write: metadata=%+v error=%v", metadata, err)
			}
			close(writeReturned)
		}()
		<-transport.writeStarted
		go func() { w.Close(); close(closed) }()
		<-transport.entered

		// Cancellation makes the writer's caller invoke Close again. It must
		// join the transport fence, not mistake stopped admission for closed IO.
		cancel()
		synctest.Wait()
		select {
		case <-writeReturned:
			t.Fatal("in-flight cancellation returned before the transport was fenced")
		default:
		}
	})
}
