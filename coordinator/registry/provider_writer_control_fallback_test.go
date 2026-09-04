package registry

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"
)

// TestEnqueueControlOrWaitReturnsOnTeardown: a caller parked in the blocking
// control-lane fallback (control lane full behind a stalled data write) must
// return promptly when the connection is torn down, so a dead provider cannot
// pin its MaxControlFallbacksInFlight goroutines for the whole fallback
// timeout — every writer exit path drains its lanes and closes done.
func TestEnqueueControlOrWaitReturnsOnTeardown(t *testing.T) {
	serverConn, _ := testWebSocketPair(t) // client never reads: the data write stalls
	p := &Provider{Conn: serverConn, writer: newProviderWriter(serverConn)}
	w := p.writer
	w.timeoutFor = func(int) time.Duration { return time.Minute } // the watchdog is not under test

	go func() { _ = p.WriteText(context.Background(), bytes.Repeat([]byte("x"), 32<<20)) }()
	deadline := time.Now().Add(3 * time.Second)
	for !p.WriteInFlight() {
		if time.Now().After(deadline) {
			t.Fatal("data write never became in-flight")
		}
		time.Sleep(5 * time.Millisecond)
	}
	for i := 0; i < providerControlQueueSize+1; i++ {
		if err := p.EnqueueText(context.Background(), []byte(`{"type":"cancel"}`)); errors.Is(err, ErrProviderWriterQueueFull) {
			break
		}
	}

	parked := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_, err := p.EnqueueControlOrWait(ctx, []byte(`{"type":"cancel","request_id":"parked"}`))
		parked <- err
	}()
	time.Sleep(100 * time.Millisecond)
	select {
	case err := <-parked:
		t.Fatalf("fallback returned (%v) while the lane was full and the writer alive", err)
	default:
	}

	start := time.Now()
	p.closeWriterNow()
	select {
	case err := <-parked:
		if !errors.Is(err, ErrProviderWriterStopped) {
			t.Fatalf("parked fallback returned %v after teardown, want ErrProviderWriterStopped", err)
		}
		if took := time.Since(start); took > time.Second {
			t.Fatalf("parked fallback took %v to return after teardown", took)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("parked control-lane fallback did not return after the connection was torn down")
	}
}
