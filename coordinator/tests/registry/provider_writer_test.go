package registry_test

import (
	"context"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	providerwrite "github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"nhooyr.io/websocket"

	production "github.com/eigeninference/d-inference/coordinator/registry"
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

func TestProviderWriteTextCanceledContextDoesNotCloseSocket(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	r := production.New(testLogger())
	p := r.Register("writer-contract", serverConn, &protocol.RegisterMessage{})
	t.Cleanup(func() { r.Disconnect(p.ID) })

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
	w := newWriterFixture(1, 0, nil, nil, nil, nil)
	w.offer(providerwrite.NewFrame(nil, nil), false)

	if err := w.Write(context.Background(), []byte(`{"type":"overflow"}`)); err != providerwrite.ErrQueueFull {
		t.Fatalf("write on full queue = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.Enqueue(context.Background(), []byte(`{"type":"overflow"}`)); err != providerwrite.ErrQueueFull {
		t.Fatalf("enqueue on full queue = %v, want errProviderWriterQueueFull", err)
	}
}

func TestProviderWriteTextCancellationBeforeStartSkipsFrame(t *testing.T) {
	w := newWriterFixture(1, 0, nil, nil, nil, nil)
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() {
		errCh <- w.Write(ctx, []byte(`{"type":"skip"}`))
	}()

	var req *providerwrite.Request
	select {
	case req = <-w.lanes.Receive(false):
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
	if !req.CanceledBeforeHandoff() {
		// No consumer has executed this dequeued request; the only alternative
		// to cancellation is the original queued ownership (state zero).
		t.Fatalf("queued request state = %d, want canceled-before-start state 1", 0)
	}
}

func TestProviderWriteDeferredBuildsAtDequeue(t *testing.T) {
	var built atomic.Bool
	var handoffObserved atomic.Bool
	var writeBeforeHandoff atomic.Bool
	written := make(chan string, 1)
	w := newWriterFixture(1, 1, nil, nil, func(data []byte) error {
		if !handoffObserved.Load() {
			writeBeforeHandoff.Store(true)
		}
		written <- string(data)
		return nil
	}, nil)
	metadataCh := make(chan production.TextFrameWriteMetadata, 1)
	errCh := make(chan error, 1)
	go func() {
		metadata, err := w.WriteDeferred(context.Background(), func(time.Time) ([]byte, error) {
			built.Store(true)
			return []byte(`{"built":"at-dequeue"}`), nil
		}, func(production.TextFrameWriteMetadata) {
			handoffObserved.Store(true)
		})
		metadataCh <- metadata
		errCh <- err
	}()
	deadline := time.Now().Add(time.Second)
	for w.lanes.Depth(false) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("deferred request was not queued")
		}
		time.Sleep(time.Millisecond)
	}
	if built.Load() {
		t.Fatal("deferred frame built before writer dequeue")
	}

	go w.Run()
	t.Cleanup(w.Close)
	if err := <-errCh; err != nil {
		t.Fatalf("writeDeferred = %v", err)
	}
	if metadata := <-metadataCh; metadata.DequeuedAt.IsZero() || !metadata.Committed {
		t.Fatal("successful deferred write returned zero dequeue metadata")
	}
	if got := <-written; got != `{"built":"at-dequeue"}` {
		t.Fatalf("written frame = %s", got)
	}
	if !built.Load() {
		t.Fatal("deferred builder was not called")
	}
	if writeBeforeHandoff.Load() {
		t.Fatal("socket write started before owner acknowledged dequeue metadata")
	}
}

func TestProviderWriteDeadlineAbortsInFlightSocketWrite(t *testing.T) {
	started := make(chan struct{})
	writeExited := make(chan struct{})
	stop := make(chan struct{})
	w := newWriterFixture(1, 1, nil, nil, func(data []byte) error {
		if string(data) == `{"type":"request"}` {
			close(started)
			<-stop
		}
		close(writeExited)
		return providerwrite.ErrStopped
	}, stop)
	go w.Run()
	t.Cleanup(w.Close)

	ctx, cancel := context.WithCancel(context.Background())
	type result struct {
		metadata production.TextFrameWriteMetadata
		err      error
	}
	resultCh := make(chan result, 1)
	go func() {
		metadata, err := w.WriteDeferred(ctx, func(time.Time) ([]byte, error) {
			return []byte(`{"type":"request"}`), nil
		}, nil)
		resultCh <- result{metadata: metadata, err: err}
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("socket write did not start")
	}
	cancel()
	select {
	case got := <-resultCh:
		if got.err != context.Canceled {
			t.Fatalf("canceled write error = %v, want context.Canceled", got.err)
		}
		if got.metadata.DequeuedAt.IsZero() {
			t.Fatal("canceled in-flight write lost dequeue metadata")
		}
		if !got.metadata.Committed {
			t.Fatal("canceled in-flight write lost commitment")
		}
	case <-time.After(time.Second):
		t.Fatal("deadline did not abort in-flight socket write")
	}
	select {
	case <-writeExited:
	case <-time.After(time.Second):
		t.Fatal("socket write did not exit after writer close")
	}
	if !w.Closed() {
		t.Fatal("writer remained reusable after an aborted partial frame")
	}
}

func TestProviderWriteCompletionWinsConcurrentContextCancellation(t *testing.T) {
	writeCompleted := make(chan struct{})
	releaseDone := make(chan struct{})
	w := newWriterFixture(1, 1, nil, nil, func([]byte) error { return nil }, nil)
	go func() {
		w.executeUntilPublication(false, writeCompleted, releaseDone)
		w.Run()
	}()
	t.Cleanup(w.Close)

	ctx, cancel := context.WithCancel(context.Background())
	type result struct {
		metadata production.TextFrameWriteMetadata
		err      error
	}
	resultCh := make(chan result, 1)
	go func() {
		metadata, err := w.WriteDeferred(ctx, func(time.Time) ([]byte, error) {
			return []byte(`{"type":"request"}`), nil
		}, nil)
		resultCh <- result{metadata: metadata, err: err}
	}()

	<-writeCompleted
	cancel()
	got := <-resultCh
	if got.err != nil {
		t.Fatalf("completed write returned context cancellation: %v", got.err)
	}
	if got.metadata.DequeuedAt.IsZero() {
		t.Fatal("completed write lost dequeue metadata")
	}
	if !got.metadata.Committed {
		t.Fatal("completed write lost commitment")
	}
	if w.Closed() {
		t.Fatal("completed write cancellation killed a healthy connection")
	}

	close(releaseDone)
	if err := w.WriteControl(context.Background(), []byte(`{"type":"barrier"}`)); err != nil {
		t.Fatalf("writer was not reusable after completed write: %v", err)
	}
}

func TestProviderWriteCompletionWinsConcurrentWriterStop(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := providerwrite.NewFrame(nil, nil)
	w := newWriterFixture(1, 1, nil, nil, nil, nil)
	w.Execute(req)
	req.Publish()

	if err := providerwrite.ResultAfterStop(ctx, req); err != nil {
		t.Fatalf("completed write was reclassified by writer stop: %v", err)
	}
}

func TestProviderWriteDeferredCancellationDuringBuilderHasNoHandoff(t *testing.T) {
	builderStarted := make(chan struct{})
	releaseBuilder := make(chan struct{})
	wrote := atomic.Bool{}
	w := newWriterFixture(1, 1, nil, nil, func(data []byte) error {
		if string(data) == `{"type":"expired"}` {
			wrote.Store(true)
		}
		return nil
	}, nil)
	go w.Run()
	t.Cleanup(w.Close)

	ctx, cancel := context.WithCancel(context.Background())
	type result struct {
		metadata production.TextFrameWriteMetadata
		err      error
	}
	resultCh := make(chan result, 1)
	go func() {
		metadata, err := w.WriteDeferred(ctx, func(time.Time) ([]byte, error) {
			close(builderStarted)
			<-releaseBuilder
			return []byte(`{"type":"expired"}`), nil
		}, nil)
		resultCh <- result{metadata: metadata, err: err}
	}()

	select {
	case <-builderStarted:
	case <-time.After(time.Second):
		t.Fatal("deferred builder did not start")
	}
	cancel()

	select {
	case got := <-resultCh:
		if got.err != context.Canceled {
			t.Fatalf("write error = %v, want context.Canceled", got.err)
		}
		if !got.metadata.DequeuedAt.IsZero() {
			t.Fatalf("canceled builder reported handoff at %v", got.metadata.DequeuedAt)
		}
		if got.metadata.Committed {
			t.Fatal("canceled builder reported commitment")
		}
	case <-time.After(time.Second):
		t.Fatal("caller waited for canceled deferred builder")
	}
	close(releaseBuilder)
	if err := w.WriteControl(context.Background(), []byte(`{"type":"barrier"}`)); err != nil {
		t.Fatalf("writer barrier after canceled builder: %v", err)
	}
	if wrote.Load() {
		t.Fatal("frame reached socket after context expired during builder")
	}
}

// laneRequest builds a write request suitable for preloading a lane directly
// on a manually-constructed writer.
func laneRequest(data string) *providerwrite.Request {
	return providerwrite.NewFrame([]byte(data), nil)
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
	w := newWriterFixture(providerwrite.DataQueueSize, providerwrite.ControlQueueSize, serverConn, nil, nil, nil)
	// Preload several data frames before the writer starts, then a control
	// frame. Strict priority means the control frame hits the socket first
	// even though it was submitted last.
	w.offer(laneRequest(`{"lane":"data","i":0}`), false)
	w.offer(laneRequest(`{"lane":"data","i":1}`), false)
	w.offer(laneRequest(`{"lane":"data","i":2}`), false)
	w.offer(laneRequest(`{"lane":"control"}`), true)
	go w.Run()
	t.Cleanup(w.Close)

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
	r := production.New(testLogger())
	p := r.Register("writer-contract", serverConn, &protocol.RegisterMessage{})
	t.Cleanup(func() { r.Disconnect(p.ID) })

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
	w := newWriterFixture(providerwrite.DataQueueSize, providerwrite.ControlQueueSize, serverConn, nil, nil, nil)
	w.offer(laneRequest(`{"lane":"data","i":0}`), false)
	w.offer(laneRequest(`{"lane":"data","i":1}`), false)
	if err := w.Enqueue(context.Background(), []byte(`{"lane":"control","via":"enqueue"}`)); err != nil {
		t.Fatalf("enqueue = %v", err)
	}
	if got := w.lanes.Depth(true); got != 1 {
		t.Fatalf("control lane depth after enqueue = %d, want 1 (enqueue must use the control lane)", got)
	}
	if got := w.lanes.Depth(false); got != 2 {
		t.Fatalf("data lane depth after enqueue = %d, want 2", got)
	}

	go w.Run()
	t.Cleanup(w.Close)
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
	r := production.New(testLogger())
	p := r.Register("writer-contract", serverConn, &protocol.RegisterMessage{})
	t.Cleanup(func() { r.Disconnect(p.ID) })

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
	w := newWriterFixture(1, 1, nil, nil, nil, nil)

	// Control lane full: enqueue and writeControl fail fast, but the data
	// lane still accepts (lanes are independent).
	w.offer(laneRequest(`{"preloaded":"control"}`), true)
	if err := w.Enqueue(context.Background(), []byte(`{"overflow":1}`)); err != providerwrite.ErrQueueFull {
		t.Fatalf("enqueue on full control lane = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.WriteControl(context.Background(), []byte(`{"overflow":2}`)); err != providerwrite.ErrQueueFull {
		t.Fatalf("writeControl on full control lane = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.lanes.Offer(laneRequest(`{"lane":"data"}`), false, w.Done()); err != nil {
		t.Fatalf("data lane submit while control lane full = %v, want nil", err)
	}

	// Data lane full (holds the frame from above): write fails fast, but the
	// control lane (drained) accepts again.
	<-w.lanes.Receive(true)
	if err := w.Write(context.Background(), []byte(`{"overflow":3}`)); err != providerwrite.ErrQueueFull {
		t.Fatalf("write on full data lane = %v, want errProviderWriterQueueFull", err)
	}
	if err := w.Enqueue(context.Background(), []byte(`{"lane":"control"}`)); err != nil {
		t.Fatalf("enqueue while data lane full = %v, want nil", err)
	}
}

// TestProviderWriterWatchdogClosesStalledWrite stalls a write by never reading
// on the client side and pushing an incompressible frame far larger than the
// kernel TCP buffers. With an injected 50ms deadline, the watchdog must close
// the socket and the write must surface providerwrite.ErrTimeout.
func TestProviderWriterWatchdogClosesStalledWrite(t *testing.T) {
	serverConn, _ := testWebSocketPair(t) // client never reads
	transport := providerwrite.NewSocketTransport(serverConn, func(int) time.Duration { return 50 * time.Millisecond })
	w := providerwrite.New(transport, providerwrite.NewLanes(1, 1))
	go w.Run()
	t.Cleanup(w.Close)

	payload := make([]byte, 32<<20)
	rng := rand.New(rand.NewSource(1)) // incompressible so negotiated compression cannot shrink it
	rng.Read(payload)

	errCh := make(chan error, 1)
	go func() { errCh <- w.Write(context.Background(), payload) }()
	select {
	case err := <-errCh:
		if err != providerwrite.ErrTimeout {
			t.Fatalf("stalled write error = %v, want errProviderWriteTimeout", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for watchdog to abort the stalled write")
	}
	if !transport.TimedOut() {
		t.Fatal("writeTimedOut not set by watchdog")
	}
	select {
	case <-w.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("writer did not shut down after watchdog closed the socket")
	}
	if err := w.Write(context.Background(), []byte(`{"after":"close"}`)); err != providerwrite.ErrStopped {
		t.Fatalf("write after watchdog close = %v, want errProviderWriterStopped", err)
	}
}

func TestSendModelLoadActionsClearsPendingWhenWriterQueueFull(t *testing.T) {
	w := newWriterFixture(1, 0, nil, nil, nil, nil)
	loads := &pendingload.Ledger{}
	var planner *production.ModelLoadPlanner
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		Connections:  retainedWriterFactory{writer: w.Writer},
		PendingLoads: loads,
		ModelLoadPlanning: func(actual *production.ModelLoadPlanner) production.ModelLoadPlanning {
			planner = actual
			return actual
		},
	})
	p := r.Register("queue-full-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "m"}},
	})
	t.Cleanup(func() { r.Disconnect(p.ID) })
	w.offer(providerwrite.NewFrame(nil, nil), false)

	actions := planner.Reserve([]production.ModelLoadAction{{ProviderID: p.ID, ModelID: "m"}}, time.Now())
	if len(actions) != 1 {
		t.Fatalf("reserved actions = %d, want 1", len(actions))
	}
	planner.Send(actions)

	if loads.HasProvider(p.ID) {
		t.Fatal("pending model load was not cleared after writer queue rejected load_model")
	}
}
