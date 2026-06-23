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
		controlQueue: make(chan *providerWriteRequest, 1),
		queue:        make(chan *providerWriteRequest, 1),
		done:         make(chan struct{}),
	}
	w.queue <- &providerWriteRequest{done: make(chan error, 1)}
	w.controlQueue <- &providerWriteRequest{done: make(chan error, 1)}

	if err := w.write(context.Background(), []byte(`{"type":"overflow"}`)); err != errProviderWriterQueueFull {
		t.Fatalf("write on full queue = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.enqueue(context.Background(), []byte(`{"type":"overflow"}`)); err != errProviderWriterQueueFull {
		t.Fatalf("enqueue on full queue = %v, want errProviderWriterQueueFull", err)
	}
}

func TestProviderWriteTextCancellationBeforeStartSkipsFrame(t *testing.T) {
	w := &providerWriter{
		controlQueue: make(chan *providerWriteRequest, 1),
		queue:        make(chan *providerWriteRequest, 1),
		done:         make(chan struct{}),
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

func TestProviderWriterPrioritizesControlFrames(t *testing.T) {
	w := &providerWriter{
		controlQueue: make(chan *providerWriteRequest, 1),
		queue:        make(chan *providerWriteRequest, 1),
		stop:         make(chan struct{}),
		done:         make(chan struct{}),
	}
	normal := &providerWriteRequest{data: []byte(`{"type":"inference"}`)}
	control := &providerWriteRequest{data: []byte(`{"type":"cancel"}`)}
	w.queue <- normal
	w.controlQueue <- control

	got, ok := w.next()
	if !ok {
		t.Fatal("next stopped unexpectedly")
	}
	if got != control {
		t.Fatalf("first frame = %s, want control frame", got.data)
	}
	got, ok = w.next()
	if !ok {
		t.Fatal("next stopped unexpectedly after control frame")
	}
	if got != normal {
		t.Fatalf("second frame = %s, want normal frame", got.data)
	}
}

func TestProviderControlEnqueueBypassesFullDataQueue(t *testing.T) {
	w := &providerWriter{
		controlQueue: make(chan *providerWriteRequest, 1),
		queue:        make(chan *providerWriteRequest, 1),
		done:         make(chan struct{}),
	}
	w.queue <- &providerWriteRequest{done: make(chan error, 1)}

	if err := w.write(context.Background(), []byte(`{"type":"inference"}`)); err != errProviderWriterQueueFull {
		t.Fatalf("write on full data queue = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.enqueue(context.Background(), []byte(`{"type":"cancel"}`)); err != nil {
		t.Fatalf("control enqueue with full data queue = %v, want nil", err)
	}
}

func TestProviderControlWriterUsesAttachedControlSocket(t *testing.T) {
	dataServerConn, dataClientConn := testWebSocketPair(t)
	controlServerConn, controlClientConn := testWebSocketPair(t)
	p := &Provider{Conn: dataServerConn, writer: newProviderWriter(dataServerConn)}
	t.Cleanup(p.closeWriterNow)
	if err := p.AttachControlConn(controlServerConn); err != nil {
		t.Fatalf("AttachControlConn: %v", err)
	}

	if err := p.WriteControlText(context.Background(), []byte(`{"type":"cancel","request_id":"r1"}`)); err != nil {
		t.Fatalf("WriteControlText: %v", err)
	}
	readCtx, cancelRead := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelRead()
	_, data, err := controlClientConn.Read(readCtx)
	if err != nil {
		t.Fatalf("control client read: %v", err)
	}
	if string(data) != `{"type":"cancel","request_id":"r1"}` {
		t.Fatalf("control data = %s", data)
	}

	// The primary data socket must remain available for inference frames.
	if err := p.WriteText(context.Background(), []byte(`{"type":"inference_request","request_id":"r2"}`)); err != nil {
		t.Fatalf("WriteText: %v", err)
	}
	readCtx2, cancelRead2 := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelRead2()
	_, data, err = dataClientConn.Read(readCtx2)
	if err != nil {
		t.Fatalf("data client read: %v", err)
	}
	if string(data) != `{"type":"inference_request","request_id":"r2"}` {
		t.Fatalf("data frame = %s", data)
	}

	p.ClearControlConn(controlServerConn)
	if err := p.WriteControlText(context.Background(), []byte(`{"type":"cancel","request_id":"r3"}`)); err != nil {
		t.Fatalf("WriteControlText after ClearControlConn: %v", err)
	}
	readCtx3, cancelRead3 := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelRead3()
	_, data, err = dataClientConn.Read(readCtx3)
	if err != nil {
		t.Fatalf("data client fallback read: %v", err)
	}
	if string(data) != `{"type":"cancel","request_id":"r3"}` {
		t.Fatalf("fallback control frame = %s", data)
	}
}

func TestProviderControlWriterFallsBackWhenControlWriterStopped(t *testing.T) {
	dataServerConn, dataClientConn := testWebSocketPair(t)
	controlServerConn, _ := testWebSocketPair(t)
	p := &Provider{Conn: dataServerConn, writer: newProviderWriter(dataServerConn)}
	t.Cleanup(p.closeWriterNow)
	if err := p.AttachControlConn(controlServerConn); err != nil {
		t.Fatalf("AttachControlConn: %v", err)
	}

	p.mu.Lock()
	staleControlWriter := p.controlWriter
	p.mu.Unlock()
	staleControlWriter.closeNow()

	if err := p.WriteControlText(context.Background(), []byte(`{"type":"cancel","request_id":"stale"}`)); err != nil {
		t.Fatalf("WriteControlText with stale control writer: %v", err)
	}
	readCtx, cancelRead := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelRead()
	_, data, err := dataClientConn.Read(readCtx)
	if err != nil {
		t.Fatalf("data client fallback read: %v", err)
	}
	if string(data) != `{"type":"cancel","request_id":"stale"}` {
		t.Fatalf("stale fallback control frame = %s", data)
	}
}

func TestSendModelLoadActionsClearsPendingWhenWriterQueueFull(t *testing.T) {
	r := New(testLogger())
	p := &Provider{
		ID:          "queue-full-provider",
		writer:      &providerWriter{controlQueue: make(chan *providerWriteRequest, 1), queue: make(chan *providerWriteRequest, 1), done: make(chan struct{})},
		pendingReqs: make(map[string]*PendingRequest),
	}
	p.writer.controlQueue <- &providerWriteRequest{done: make(chan error, 1)}
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

func TestSendModelLoadActionsUsesControlQueueWhenDataQueueFull(t *testing.T) {
	r := New(testLogger())
	p := &Provider{
		ID:          "data-full-provider",
		writer:      &providerWriter{controlQueue: make(chan *providerWriteRequest, 1), queue: make(chan *providerWriteRequest, 1), done: make(chan struct{})},
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
	if !hasPending {
		t.Fatal("pending model load was cleared even though control queue accepted load_model")
	}
	select {
	case req := <-p.writer.controlQueue:
		if !strings.Contains(string(req.data), `"load_model"`) {
			t.Fatalf("queued control frame = %s, want load_model", req.data)
		}
	default:
		t.Fatal("load_model was not queued on the control queue")
	}
}
