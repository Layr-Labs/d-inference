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

func TestProviderWriteTextControlDeliversOnLiveSocket(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	p := &Provider{Conn: serverConn, writer: newProviderWriter(serverConn)}
	t.Cleanup(p.closeWriterNow)

	if err := p.WriteTextControl(context.Background(), []byte(`{"type":"attestation_challenge"}`)); err != nil {
		t.Fatalf("WriteTextControl = %v", err)
	}
	frames := readFrames(t, clientConn, 1)
	if frames[0] != `{"type":"attestation_challenge"}` {
		t.Fatalf("frame = %s, want attestation_challenge", frames[0])
	}
}

// TestWriteTextThenEnqueueTextPreservesOrdering pins the ordering contract
// that request→cancel call sites rely on: WriteText (data lane) blocks until
// its frame has been written to the socket, so a control frame enqueued via
// EnqueueText AFTER WriteText returned can never precede the data frame on
// the wire. This holds despite the control lane's strict priority — the data
// frame is already gone by the time the control frame is submitted.
// Cross-lane ordering is otherwise unspecified: a control frame submitted
// while a data frame is still queued may overtake it.
func TestWriteTextThenEnqueueTextPreservesOrdering(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	p := &Provider{Conn: serverConn, writer: newProviderWriter(serverConn)}
	t.Cleanup(p.closeWriterNow)

	if err := p.WriteText(context.Background(), []byte(`{"type":"request"}`)); err != nil {
		t.Fatalf("WriteText = %v", err)
	}
	if err := p.EnqueueText(context.Background(), []byte(`{"type":"cancel"}`)); err != nil {
		t.Fatalf("EnqueueText = %v", err)
	}

	frames := readFrames(t, clientConn, 2)
	want := []string{`{"type":"request"}`, `{"type":"cancel"}`}
	for i := range want {
		if frames[i] != want[i] {
			t.Fatalf("frame[%d] = %s, want %s (all frames: %v)", i, frames[i], want[i], frames)
		}
	}
}

func TestSendModelLoadActionsClearsPendingWhenWriterQueueFull(t *testing.T) {
	r := New(testLogger())
	serverConn, _ := testWebSocketPair(t)
	p := &Provider{
		ID:          "queue-full-provider",
		Conn:        serverConn,
		writer:      newProviderWriter(serverConn),
		pendingReqs: make(map[string]*PendingRequest),
	}
	fillProviderDataQueue(t, p)
	insertTestProvider(r, p)

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
