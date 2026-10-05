package registry_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/writedeadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/writertransport"
	"nhooyr.io/websocket"
)

func TestProviderWriteTimeoutScalesWithFrameSize(t *testing.T) {
	if got := writertransport.Timeout(1); got != 5*time.Second {
		t.Fatalf("tiny frame timeout = %v, want min %v", got, 5*time.Second)
	}
	large := (2 << 20) * 10
	if got := writertransport.Timeout(large); got != 10*time.Second {
		t.Fatalf("large frame timeout = %v, want 10s", got)
	}
	tooLarge := (2 << 20) * 100
	if got := writertransport.Timeout(tooLarge); got != 30*time.Second {
		t.Fatalf("huge frame timeout = %v, want max %v", got, 30*time.Second)
	}
}

// TestProviderWriterWatchdogFiresOnPastDeadline unit-tests watchWrites: a
// published deadline in the past makes the watchdog set writeTimedOut and
// close the socket within one tick.
func TestProviderWriterWatchdogFiresOnPastDeadline(t *testing.T) {
	serverConn, _ := transportWebSocketPair(t)
	w := &writedeadline.Watchdog{}
	w.Deadline.Store(time.Now().Add(-time.Second).UnixNano())
	watchdogStop := make(chan struct{})
	defer close(watchdogStop)
	go w.Watch(serverConn, watchdogStop, nil)

	deadline := time.Now().Add(5 * time.Second)
	for !w.TimedOut.Load() {
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
func transportWebSocketPair(t *testing.T) (*websocket.Conn, *websocket.Conn) {
	t.Helper()
	serverConnCh := make(chan *websocket.Conn, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Errorf("accept websocket: %v", err)
			return
		}
		serverConnCh <- conn
	}))
	t.Cleanup(server.Close)

	dialCtx, cancelDial := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelDial()
	clientConn, _, err := websocket.Dial(dialCtx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	t.Cleanup(func() { _ = clientConn.Close(websocket.StatusNormalClosure, "done") })

	select {
	case serverConn := <-serverConnCh:
		t.Cleanup(func() { _ = serverConn.Close(websocket.StatusNormalClosure, "done") })
		return serverConn, clientConn
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for server websocket")
	}
	return nil, nil
}
