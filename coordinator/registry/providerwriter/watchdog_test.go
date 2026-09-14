package providerwriter

import (
	"context"
	"math/rand"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// TestProviderWriterWatchdogClosesStalledWrite stalls a write by never reading
// on the client side and pushing an incompressible frame far larger than the
// kernel TCP buffers. With an injected 50ms deadline, the watchdog must close
// the socket and the write must surface errWriteTimeout.
func TestProviderWriterWatchdogClosesStalledWrite(t *testing.T) {
	serverConn, _ := testWebSocketPair(t) // client never reads
	w := &Writer{
		conn:       serverConn,
		queue:      make(chan *writeRequest, 1),
		control:    make(chan *writeRequest, 1),
		stop:       make(chan struct{}),
		done:       make(chan struct{}),
		timeoutFor: func(int) time.Duration { return 50 * time.Millisecond },
	}
	go w.run()
	t.Cleanup(w.CloseNow)

	payload := make([]byte, 32<<20)
	rng := rand.New(rand.NewSource(1)) // incompressible so negotiated compression cannot shrink it
	rng.Read(payload)

	errCh := make(chan error, 1)
	go func() { errCh <- w.Write(context.Background(), payload) }()
	select {
	case err := <-errCh:
		if err != errWriteTimeout {
			t.Fatalf("stalled write error = %v, want errProviderWriteTimeout", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for watchdog to abort the stalled write")
	}
	if !w.writeTimedOut.Load() {
		t.Fatal("writeTimedOut not set by watchdog")
	}
	select {
	case <-w.done:
	case <-time.After(5 * time.Second):
		t.Fatal("writer did not shut down after watchdog closed the socket")
	}
	if err := w.Write(context.Background(), []byte(`{"after":"close"}`)); err != errStopped {
		t.Fatalf("write after watchdog close = %v, want errProviderWriterStopped", err)
	}
}

// TestProviderWriterWatchdogFiresOnPastDeadline unit-tests watchWrites: a
// published deadline in the past makes the watchdog set writeTimedOut and
// close the socket within one tick.
func TestProviderWriterWatchdogFiresOnPastDeadline(t *testing.T) {
	serverConn, _ := testWebSocketPair(t)
	w := &Writer{
		conn: serverConn,
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}
	w.writeDeadline.Store(time.Now().Add(-time.Second).UnixNano())
	watchdogStop := make(chan struct{})
	defer close(watchdogStop)
	go w.watchWrites(watchdogStop)

	deadline := time.Now().Add(5 * time.Second)
	for !w.writeTimedOut.Load() {
		if time.Now().After(deadline) {
			t.Fatal("watchdog did not fire on a past write deadline")
		}
		time.Sleep(10 * time.Millisecond)
	}
	writeCtx, cancelWrite := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelWrite()
	if err := serverConn.Write(writeCtx, websocket.MessageText, []byte(`{"x":1}`)); err == nil {
		t.Fatal("expected write on watchdog-closed socket to fail")
	}
}
