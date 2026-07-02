package registry

import (
	"context"
	"math/rand"
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

// laneRequest builds a write request suitable for preloading a lane directly
// on a manually-constructed writer.
func laneRequest(data string) *providerWriteRequest {
	return &providerWriteRequest{
		ctx:  context.Background(),
		data: []byte(data),
		done: make(chan error, 1),
	}
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

func TestProviderWriterControlLanePriority(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	w := &providerWriter{
		conn:    serverConn,
		queue:   make(chan *providerWriteRequest, providerWriteQueueSize),
		control: make(chan *providerWriteRequest, providerControlQueueSize),
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
	t.Cleanup(w.closeNow)

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

func TestProviderWriterEnqueueUsesControlLane(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	w := &providerWriter{
		conn:    serverConn,
		queue:   make(chan *providerWriteRequest, providerWriteQueueSize),
		control: make(chan *providerWriteRequest, providerControlQueueSize),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	w.queue <- laneRequest(`{"lane":"data","i":0}`)
	w.queue <- laneRequest(`{"lane":"data","i":1}`)
	if err := w.enqueue(context.Background(), []byte(`{"lane":"control","via":"enqueue"}`)); err != nil {
		t.Fatalf("enqueue = %v", err)
	}
	if got := len(w.control); got != 1 {
		t.Fatalf("control lane depth after enqueue = %d, want 1 (enqueue must use the control lane)", got)
	}
	if got := len(w.queue); got != 2 {
		t.Fatalf("data lane depth after enqueue = %d, want 2", got)
	}

	go w.run()
	t.Cleanup(w.closeNow)
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

func TestProviderWriterQueueFullPerLane(t *testing.T) {
	w := &providerWriter{
		queue:   make(chan *providerWriteRequest, 1),
		control: make(chan *providerWriteRequest, 1),
		done:    make(chan struct{}),
	}

	// Control lane full: enqueue and writeControl fail fast, but the data
	// lane still accepts (lanes are independent).
	w.control <- laneRequest(`{"preloaded":"control"}`)
	if err := w.enqueue(context.Background(), []byte(`{"overflow":1}`)); err != errProviderWriterQueueFull {
		t.Fatalf("enqueue on full control lane = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.writeControl(context.Background(), []byte(`{"overflow":2}`)); err != errProviderWriterQueueFull {
		t.Fatalf("writeControl on full control lane = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.submit(w.queue, laneRequest(`{"lane":"data"}`)); err != nil {
		t.Fatalf("data lane submit while control lane full = %v, want nil", err)
	}

	// Data lane full (holds the frame from above): write fails fast, but the
	// control lane (drained) accepts again.
	<-w.control
	if err := w.write(context.Background(), []byte(`{"overflow":3}`)); err != errProviderWriterQueueFull {
		t.Fatalf("write on full data lane = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.enqueue(context.Background(), []byte(`{"lane":"control"}`)); err != nil {
		t.Fatalf("enqueue while data lane full = %v, want nil", err)
	}
}

// TestProviderWriterWatchdogClosesStalledWrite stalls a write by never reading
// on the client side and pushing an incompressible frame far larger than the
// kernel TCP buffers. With an injected 50ms deadline, the watchdog must close
// the socket and the write must surface errProviderWriteTimeout.
func TestProviderWriterWatchdogClosesStalledWrite(t *testing.T) {
	serverConn, _ := testWebSocketPair(t) // client never reads
	w := &providerWriter{
		conn:       serverConn,
		queue:      make(chan *providerWriteRequest, 1),
		control:    make(chan *providerWriteRequest, 1),
		stop:       make(chan struct{}),
		done:       make(chan struct{}),
		timeoutFor: func(int) time.Duration { return 50 * time.Millisecond },
	}
	go w.run()
	t.Cleanup(w.closeNow)

	payload := make([]byte, 32<<20)
	rng := rand.New(rand.NewSource(1)) // incompressible so negotiated compression cannot shrink it
	rng.Read(payload)

	errCh := make(chan error, 1)
	go func() { errCh <- w.write(context.Background(), payload) }()
	select {
	case err := <-errCh:
		if err != errProviderWriteTimeout {
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
	if err := w.write(context.Background(), []byte(`{"after":"close"}`)); err != errProviderWriterStopped {
		t.Fatalf("write after watchdog close = %v, want errProviderWriterStopped", err)
	}
}

// TestProviderWriterWatchdogFiresOnPastDeadline unit-tests watchWrites: a
// published deadline in the past makes the watchdog set writeTimedOut and
// close the socket within one tick.
func TestProviderWriterWatchdogFiresOnPastDeadline(t *testing.T) {
	serverConn, _ := testWebSocketPair(t)
	w := &providerWriter{
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
