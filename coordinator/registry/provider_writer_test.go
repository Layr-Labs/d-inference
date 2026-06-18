package registry

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

func TestProviderWriteTimeoutScalesWithFrameSize(t *testing.T) {
	if got := providerWriteTimeout(1); got != providerWriteMinTimeout {
		t.Fatalf("tiny frame timeout = %v, want min %v", got, providerWriteMinTimeout)
	}
	large := providerWriteBytesPerSecond * 10
	if got := providerWriteTimeout(large); got != 10*time.Second {
		t.Fatalf("large frame timeout = %v, want 10s", got)
	}
	tooLarge := providerWriteBytesPerSecond * 100
	if got := providerWriteTimeout(tooLarge); got != providerWriteMaxTimeout {
		t.Fatalf("huge frame timeout = %v, want max %v", got, providerWriteMaxTimeout)
	}
}

func TestProviderWriteTextCanceledContextDoesNotCloseSocket(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	p := &Provider{Conn: serverConn, writer: newProviderWriter(serverConn)}
	t.Cleanup(p.closeWriterNow)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := p.WriteText(ctx, []byte(`{"type":"ignored"}`)); err != context.Canceled {
		t.Fatalf("WriteText canceled ctx error = %v, want context.Canceled", err)
	}

	if err := p.WriteText(context.Background(), []byte(`{"type":"ok"}`)); err != nil {
		t.Fatalf("WriteText after canceled enqueue = %v", err)
	}
	readCtx, cancelRead := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelRead()
	_, data, err := clientConn.Read(readCtx)
	if err != nil {
		t.Fatalf("client read after canceled enqueue: %v", err)
	}
	if string(data) != `{"type":"ok"}` {
		t.Fatalf("data = %s", data)
	}
}

func TestProviderWriterQueueFullReturnsImmediately(t *testing.T) {
	w := &providerWriter{
		queue: make(chan *providerWriteRequest, 1),
		done:  make(chan struct{}),
	}
	w.queue <- &providerWriteRequest{done: make(chan error, 1)}

	if err := w.write(context.Background(), []byte(`{"type":"overflow"}`)); err != errProviderWriterQueueFull {
		t.Fatalf("write on full queue = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.enqueue(context.Background(), []byte(`{"type":"overflow"}`)); err != errProviderWriterQueueFull {
		t.Fatalf("enqueue on full queue = %v, want errProviderWriterQueueFull", err)
	}
}

func TestProviderWriteTextCancellationBeforeStartSkipsFrame(t *testing.T) {
	w := &providerWriter{
		queue: make(chan *providerWriteRequest, 1),
		done:  make(chan struct{}),
	}
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() {
		errCh <- w.write(ctx, []byte(`{"type":"skip"}`))
	}()

	var req *providerWriteRequest
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

func TestSendModelLoadActionsClearsPendingWhenWriterQueueFull(t *testing.T) {
	r := New(testLogger())
	p := &Provider{
		ID:          "queue-full-provider",
		writer:      &providerWriter{queue: make(chan *providerWriteRequest, 1), done: make(chan struct{})},
		pendingReqs: make(map[string]*PendingRequest),
	}
	p.writer.queue <- &providerWriteRequest{done: make(chan error, 1)}
	r.mu.Lock()
	r.providers[p.ID] = p
	r.mu.Unlock()

	actions := r.reservePendingModelLoads([]modelLoadAction{{providerID: p.ID, modelID: "m"}}, time.Now())
	if len(actions) != 1 {
		t.Fatalf("reserved actions = %d, want 1", len(actions))
	}
	r.sendModelLoadActions(actions)

	r.mu.Lock()
	hasPending := r.providerHasPendingLoad(p.ID)
	r.mu.Unlock()
	if hasPending {
		t.Fatal("pending model load was not cleared after writer queue rejected load_model")
	}
}
