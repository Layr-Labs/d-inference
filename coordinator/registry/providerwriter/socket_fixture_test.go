package providerwriter

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

func testWebSocketPair(t *testing.T) (*websocket.Conn, *websocket.Conn) {
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

// readFrames reads n text frames from conn, failing the test on error/timeout.
func readFrames(t *testing.T, conn *websocket.Conn, n int) []string {
	t.Helper()
	frames := make([]string, 0, n)
	for i := 0; i < n; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_, data, err := conn.Read(ctx)
		cancel()
		if err != nil {
			t.Fatalf("read frame %d: %v", i, err)
		}
		frames = append(frames, string(data))
	}
	return frames
}

// laneRequest builds a write request suitable for preloading a lane directly
// on a manually-constructed writer.
func laneRequest(data string) *writeRequest {
	return &writeRequest{
		ctx:  context.Background(),
		data: []byte(data),
		done: make(chan error, 1),
	}
}
