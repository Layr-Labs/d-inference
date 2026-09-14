package providerwriter

import (
	"context"
	"testing"
	"time"
)

func TestProviderWriteTimeoutScalesWithFrameSize(t *testing.T) {
	if got := writeTimeout(1); got != minWriteTimeout {
		t.Fatalf("tiny frame timeout = %v, want min %v", got, minWriteTimeout)
	}
	large := writeBytesPerSecond * 10
	if got := writeTimeout(large); got != 10*time.Second {
		t.Fatalf("large frame timeout = %v, want 10s", got)
	}
	tooLarge := writeBytesPerSecond * 100
	if got := writeTimeout(tooLarge); got != maxWriteTimeout {
		t.Fatalf("huge frame timeout = %v, want max %v", got, maxWriteTimeout)
	}
}

func TestProviderWriterQueueFullReturnsImmediately(t *testing.T) {
	w := &Writer{
		queue: make(chan *writeRequest, 1),
		done:  make(chan struct{}),
	}
	w.queue <- &writeRequest{done: make(chan error, 1)}

	if err := w.Write(context.Background(), []byte(`{"type":"overflow"}`)); err != errQueueFull {
		t.Fatalf("write on full queue = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.Enqueue(context.Background(), []byte(`{"type":"overflow"}`)); err != errQueueFull {
		t.Fatalf("enqueue on full queue = %v, want errProviderWriterQueueFull", err)
	}
}

func TestProviderWriteTextCancellationBeforeStartSkipsFrame(t *testing.T) {
	w := &Writer{
		queue: make(chan *writeRequest, 1),
		done:  make(chan struct{}),
	}
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() {
		errCh <- w.Write(ctx, []byte(`{"type":"skip"}`))
	}()

	var req *writeRequest
	select {
	case req = <-w.queue:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for queued write")
	}
	cancel()
	select {
	case err := <-errCh:
		if err != context.Canceled {
			t.Fatalf("write error = %v, want context.Canceled", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for canceled write")
	}
	if req.state.Load() != 1 {
		t.Fatalf("queued request state = %d, want canceled-before-start state 1", req.state.Load())
	}
}

func TestProviderWriterControlLanePriority(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	w := &Writer{
		conn:    serverConn,
		queue:   make(chan *writeRequest, dataQueueSize),
		control: make(chan *writeRequest, controlQueueSize),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	// Preload several data frames before the writer starts, then a control
	// frame. Strict priority means the control frame hits the socket first
	// even though it was submitted last.
	w.queue <- laneRequest(`{"lane":"data","i":0}`)
	w.queue <- laneRequest(`{"lane":"data","i":1}`)
	w.queue <- laneRequest(`{"lane":"data","i":2}`)
	w.control <- laneRequest(`{"lane":"control"}`)
	go w.run()
	t.Cleanup(w.CloseNow)

	frames := readFrames(t, clientConn, 4)
	want := []string{
		`{"lane":"control"}`,
		`{"lane":"data","i":0}`,
		`{"lane":"data","i":1}`,
		`{"lane":"data","i":2}`,
	}
	for i := range want {
		if frames[i] != want[i] {
			t.Fatalf("frame[%d] = %s, want %s (all frames: %v)", i, frames[i], want[i], frames)
		}
	}
}

func TestProviderWriterEnqueueUsesControlLane(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	w := &Writer{
		conn:    serverConn,
		queue:   make(chan *writeRequest, dataQueueSize),
		control: make(chan *writeRequest, controlQueueSize),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	w.queue <- laneRequest(`{"lane":"data","i":0}`)
	w.queue <- laneRequest(`{"lane":"data","i":1}`)
	if err := w.Enqueue(context.Background(), []byte(`{"lane":"control","via":"enqueue"}`)); err != nil {
		t.Fatalf("enqueue = %v", err)
	}
	if got := len(w.control); got != 1 {
		t.Fatalf("control lane depth after enqueue = %d, want 1 (enqueue must use the control lane)", got)
	}
	if got := len(w.queue); got != 2 {
		t.Fatalf("data lane depth after enqueue = %d, want 2", got)
	}

	go w.run()
	t.Cleanup(w.CloseNow)
	frames := readFrames(t, clientConn, 3)
	want := []string{
		`{"lane":"control","via":"enqueue"}`,
		`{"lane":"data","i":0}`,
		`{"lane":"data","i":1}`,
	}
	for i := range want {
		if frames[i] != want[i] {
			t.Fatalf("frame[%d] = %s, want %s (all frames: %v)", i, frames[i], want[i], frames)
		}
	}
}

func TestProviderWriterQueueFullPerLane(t *testing.T) {
	w := &Writer{
		queue:   make(chan *writeRequest, 1),
		control: make(chan *writeRequest, 1),
		done:    make(chan struct{}),
	}

	// Control lane full: Enqueue and WriteControl fail fast, but the data
	// lane still accepts (lanes are independent).
	w.control <- laneRequest(`{"preloaded":"control"}`)
	if err := w.Enqueue(context.Background(), []byte(`{"overflow":1}`)); err != errQueueFull {
		t.Fatalf("enqueue on full control lane = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.WriteControl(context.Background(), []byte(`{"overflow":2}`)); err != errQueueFull {
		t.Fatalf("writeControl on full control lane = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.submit(w.queue, laneRequest(`{"lane":"data"}`)); err != nil {
		t.Fatalf("data lane submit while control lane full = %v, want nil", err)
	}

	// Data lane full (holds the frame from above): write fails fast, but the
	// control lane (drained) accepts again.
	<-w.control
	if err := w.Write(context.Background(), []byte(`{"overflow":3}`)); err != errQueueFull {
		t.Fatalf("write on full data lane = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.Enqueue(context.Background(), []byte(`{"lane":"control"}`)); err != nil {
		t.Fatalf("enqueue while data lane full = %v, want nil", err)
	}
}
