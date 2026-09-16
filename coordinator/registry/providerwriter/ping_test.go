package providerwriter

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// TestProviderWriterFragmentedWriteAnswersPingMidMessage is the regression
// test for the 2026-08-31 provider-session teardown: a peer ping that lands
// while a multi-second data write is in flight must be answered (the pong
// interleaves between fragments), the server Read loop must survive, and the
// peer must still receive the message byte-for-byte.
//
// Before writeFragmented this failed: the client's Ping timed out, the server
// Read loop died with "failed to get reader: failed to handle control frame
// opPing: failed to write control frame opPong: failed to acquire lock:
// context deadline exceeded", and the message never completed (see
// TestUnfragmentedConnWriteStallsPeerPing, which pins that failure mode).
func TestProviderWriterFragmentedWriteAnswersPingMidMessage(t *testing.T) {
	t.Parallel()
	h := newPingStallHarness(t)
	w := New(h.serverConn)
	// The reader is throttled below the 2 MiB/s write-timeout floor on
	// purpose; the watchdog is not what is under test here.
	w.timeoutFor = func(int) time.Duration { return 60 * time.Second }
	p := w
	t.Cleanup(p.CloseNow)

	payload := stallPayload(stallMessageBytes)

	var bytesRead atomic.Int64
	pingGate := make(chan struct{})
	readDone := make(chan slowReadResult, 1)
	go func() { readDone <- readMessageSlowly(h.clientConn, &bytesRead, pingGate) }()

	writeDone := make(chan error, 1)
	writeStarted := time.Now()
	go func() { writeDone <- p.Write(context.Background(), payload) }()

	select {
	case <-pingGate:
	case res := <-readDone:
		t.Fatalf("client read finished before the ping gate: %d bytes, err=%v", len(res.data), res.err)
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for the client to read the ping gate")
	}

	pingCtx, cancelPing := context.WithTimeout(context.Background(), stallPingTimeout)
	defer cancelPing()
	pingErr := h.clientConn.Ping(pingCtx)
	bytesAtPong := bytesRead.Load()
	if pingErr != nil {
		t.Fatalf("Ping during in-flight data write = %v (pong could not interleave)", pingErr)
	}
	// The pong must have interleaved with the message, not trailed it: the
	// write is still in progress and the client has not read all of it.
	select {
	case err := <-writeDone:
		t.Fatalf("WriteText already returned (%v) when the pong arrived; the harness did not keep the write in flight", err)
	default:
	}
	if bytesAtPong >= int64(len(payload)) {
		t.Fatalf("client had read %d of %d bytes when the pong arrived; the pong did not interleave", bytesAtPong, len(payload))
	}

	select {
	case err := <-writeDone:
		if err != nil {
			t.Fatalf("WriteText = %v", err)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("timed out waiting for WriteText")
	}
	writeTook := time.Since(writeStarted)
	if writeTook < 5*time.Second {
		t.Fatalf("WriteText took %v; the throttled reader should have kept it in flight for >5s (nhooyr's pong budget)", writeTook)
	}

	var res slowReadResult
	select {
	case res = <-readDone:
	case <-time.After(60 * time.Second):
		t.Fatal("timed out waiting for the client to finish reading")
	}
	if res.err != nil {
		t.Fatalf("client read = %v after %d bytes", res.err, len(res.data))
	}
	if string(res.data) != string(payload) {
		t.Fatalf("client received %d bytes, want %d, or content differs", len(res.data), len(payload))
	}

	// Positive liveness proof for the server Read loop: it must still deliver
	// the next inbound frame, and must not have exited.
	select {
	case err := <-h.readErr:
		t.Fatalf("server Read loop exited during the fragmented write: %v", err)
	default:
	}
	writeCtx, cancelWrite := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelWrite()
	if err := h.clientConn.Write(writeCtx, websocket.MessageText, []byte(`{"type":"heartbeat"}`)); err != nil {
		t.Fatalf("client write after message: %v", err)
	}
	select {
	case msg := <-h.inbound:
		if msg != `{"type":"heartbeat"}` {
			t.Fatalf("server read %q after the fragmented write, want heartbeat", msg)
		}
	case err := <-h.readErr:
		t.Fatalf("server Read loop exited after the fragmented write: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("server Read loop did not deliver the post-message heartbeat")
	}
	t.Logf("pong arrived after %d/%d bytes; write took %v", bytesAtPong, len(payload), writeTook)
}

// TestUnfragmentedConnWriteStallsPeerPing pins the library behavior that
// motivated writeFragmented, using the pre-fix path (one nhooyr Conn.Write
// for the whole message) on the same harness: the peer's ping cannot be
// answered while the frame is in flight, and nhooyr surfaces that as a READ
// failure containing "failed to handle control frame" — the exact string
// api.readErrorDisconnectReason classifies. It also proves the harness is
// sensitive enough that the fragmented test above cannot pass vacuously.
func TestUnfragmentedConnWriteStallsPeerPing(t *testing.T) {
	t.Parallel()
	h := newPingStallHarness(t)
	payload := stallPayload(stallMessageBytes)

	var bytesRead atomic.Int64
	pingGate := make(chan struct{})
	readDone := make(chan slowReadResult, 1)
	go func() { readDone <- readMessageSlowly(h.clientConn, &bytesRead, pingGate) }()

	writeDone := make(chan error, 1)
	go func() {
		writeDone <- h.serverConn.Write(context.Background(), websocket.MessageText, payload)
	}()

	select {
	case <-pingGate:
	case res := <-readDone:
		t.Fatalf("client read finished before the ping gate: %d bytes, err=%v", len(res.data), res.err)
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for the client to read the ping gate")
	}

	pingCtx, cancelPing := context.WithTimeout(context.Background(), stallPingTimeout)
	defer cancelPing()
	pingErr := h.clientConn.Ping(pingCtx)
	if pingErr == nil {
		t.Fatal("Ping succeeded during a single-frame Conn.Write; nhooyr no longer holds the write lock for the whole message — the harness is not exercising the stall")
	}

	var readErr error
	select {
	case readErr = <-h.readErr:
	case <-time.After(15 * time.Second):
		t.Fatal("server Read loop did not fail after the unanswered ping")
	}
	// This is the string api.readErrorDisconnectReason keys on, and the
	// lock wait is the mechanism (nhooyr names the opcodes opPing/opPong).
	for _, want := range []string{"failed to handle control frame", "failed to acquire lock"} {
		if !strings.Contains(readErr.Error(), want) {
			t.Fatalf("server Read error = %q, want it to contain %q", readErr, want)
		}
	}
	t.Logf("pre-fix failure mode reproduced: Ping=%v; server Read=%v", pingErr, readErr)

	// The harness tore the socket down on the read failure, so the in-flight
	// write and the client read both fail: this is the provider-session 502
	// cascade.
	select {
	case err := <-writeDone:
		if err == nil {
			t.Fatal("single-frame Write completed after the Read loop died")
		}
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for the stalled Write to fail")
	}
	select {
	case res := <-readDone:
		if res.err == nil {
			t.Fatalf("client read completed (%d bytes) after the server session died", len(res.data))
		}
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for the client read to fail")
	}
}
