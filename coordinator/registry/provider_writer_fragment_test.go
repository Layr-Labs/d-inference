package registry

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"io"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// TestWriteFragmentedReassemblesIntact proves a payload above the fragment
// threshold arrives at the peer as one message with identical bytes, and that
// a payload below it still takes the single-frame path.
func TestWriteFragmentedReassemblesIntact(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	clientConn.SetReadLimit(64 << 20)
	w := newProviderWriter(serverConn)
	t.Cleanup(w.closeNow)

	payload := make([]byte, 3*providerWriteFragmentBytes+123)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	// Frames must be valid UTF-8 for a text message; base64 keeps it simple.
	payload = []byte(base64Of(payload))

	readErr := make(chan error, 1)
	got := make(chan []byte, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		typ, data, err := clientConn.Read(ctx)
		if err != nil {
			readErr <- err
			return
		}
		if typ != websocket.MessageText {
			readErr <- errors.New("expected text message")
			return
		}
		got <- data
	}()

	if err := w.write(context.Background(), payload); err != nil {
		t.Fatalf("write: %v", err)
	}
	select {
	case err := <-readErr:
		t.Fatalf("client read: %v", err)
	case data := <-got:
		if !bytes.Equal(data, payload) {
			t.Fatalf("reassembled payload differs: got %d bytes, want %d", len(data), len(payload))
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for reassembled message")
	}
	stats := LinkStatsSnapshot{}
	w.fillLinkStats(&stats)
	if stats.FragmentedFramesOut != 1 {
		t.Fatalf("FragmentedFramesOut = %d, want 1", stats.FragmentedFramesOut)
	}
	if stats.DataFramesOut != 1 || stats.DataBytesOut != uint64(len(payload)) {
		t.Fatalf("data lane counters = %+v", stats)
	}

	// Small frame: single-frame path, no fragmentation counted.
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, data, err := clientConn.Read(ctx)
		if err != nil {
			readErr <- err
			return
		}
		got <- data
	}()
	if err := w.write(context.Background(), []byte(`{"small":true}`)); err != nil {
		t.Fatalf("small write: %v", err)
	}
	select {
	case err := <-readErr:
		t.Fatalf("client read: %v", err)
	case data := <-got:
		if string(data) != `{"small":true}` {
			t.Fatalf("small frame = %q", data)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for small message")
	}
	w.fillLinkStats(&stats)
	if stats.FragmentedFramesOut != 1 || stats.DataFramesOut != 2 {
		t.Fatalf("counters after small write = %+v", stats)
	}
}

// TestPongInterleavesWithLargeFragmentedWrite is the regression test for the
// pong-starvation disconnect: while the coordinator is mid-way through a large
// data write to a slowly-reading provider, the provider's ping must still be
// answered inside the library's 5s control budget. With a single-frame write
// the pong waits for the whole payload (here ~6s of slow reading) and the
// library kills the connection; with fragmented writes it interleaves.
func TestPongInterleavesWithLargeFragmentedWrite(t *testing.T) {
	if testing.Short() {
		t.Skip("slow-reader test (~6s)")
	}
	serverConn, clientConn := testWebSocketPair(t)
	clientConn.SetReadLimit(64 << 20)
	// The coordinator's read loop must be running for the library to answer
	// pings (control frames are handled inside Read).
	readCtx, stopRead := context.WithCancel(context.Background())
	t.Cleanup(stopRead)
	go func() {
		for {
			if _, _, err := serverConn.Read(readCtx); err != nil {
				return
			}
		}
	}()
	w := newProviderWriter(serverConn)
	t.Cleanup(w.closeNow)

	const payloadBytes = 16 << 20
	payload := bytes.Repeat([]byte("a"), payloadBytes)

	writeDone := make(chan error, 1)
	go func() { writeDone <- w.write(context.Background(), payload) }()

	// Slow reader: ~256 KiB every 100ms => ~6.4s for 16 MiB, far beyond the
	// library's 5s control-frame budget.
	readDone := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_, r, err := clientConn.Reader(ctx)
		if err != nil {
			readDone <- err
			return
		}
		buf := make([]byte, 256<<10)
		total := 0
		for {
			n, err := io.ReadFull(r, buf)
			total += n
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				break
			}
			if err != nil {
				readDone <- err
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
		if total != payloadBytes {
			readDone <- errors.New("short read")
			return
		}
		readDone <- nil
	}()

	// Give the write time to be genuinely in flight, then ping. A healthy
	// link answers within a few fragments; use the same 5s budget the
	// library applies so a regression to single-frame writes fails here.
	time.Sleep(1 * time.Second)
	pingCtx, cancelPing := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelPing()
	pingStart := time.Now()
	if err := clientConn.Ping(pingCtx); err != nil {
		t.Fatalf("ping during large write failed (pong starved): %v", err)
	}
	if rtt := time.Since(pingStart); rtt > 3*time.Second {
		t.Fatalf("pong took %v; fragments are not releasing the frame mutex", rtt)
	}

	if err := <-readDone; err != nil {
		t.Fatalf("client read: %v", err)
	}
	if err := <-writeDone; err != nil {
		t.Fatalf("write: %v", err)
	}
}

// TestEnqueueOrWaitFallsBackWhenControlLaneFull: a full control lane rejects
// enqueue() but enqueueOrWait waits for a slot and still delivers.
func TestEnqueueOrWaitFallsBackWhenControlLaneFull(t *testing.T) {
	w := &providerWriter{
		queue:   make(chan *providerWriteRequest, 1),
		control: make(chan *providerWriteRequest, 1),
		done:    make(chan struct{}),
	}
	w.control <- laneRequest(`{"preloaded":"control"}`)

	if err := w.enqueue(context.Background(), []byte(`{"cancel":1}`)); err != errProviderWriterQueueFull {
		t.Fatalf("enqueue on full lane = %v, want queue full", err)
	}

	result := make(chan error, 1)
	fellBack := make(chan bool, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		fb, err := w.enqueueOrWait(ctx, []byte(`{"cancel":2}`))
		fellBack <- fb
		result <- err
	}()

	select {
	case err := <-result:
		t.Fatalf("enqueueOrWait returned %v before a slot freed", err)
	case <-time.After(100 * time.Millisecond):
	}
	// Free the slot: the waiting frame must land.
	<-w.control
	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("enqueueOrWait = %v, want nil", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("enqueueOrWait did not complete after a slot freed")
	}
	if !<-fellBack {
		t.Fatal("expected the blocking fallback path to be reported")
	}
	select {
	case req := <-w.control:
		if string(req.data) != `{"cancel":2}` || !req.control {
			t.Fatalf("queued frame = %q control=%v", req.data, req.control)
		}
	default:
		t.Fatal("frame was not queued on the control lane")
	}
	stats := LinkStatsSnapshot{}
	w.fillLinkStats(&stats)
	if stats.ControlQueueFull != 2 || stats.ControlFallbacks != 1 {
		t.Fatalf("counters = %+v, want ControlQueueFull=2 ControlFallbacks=1", stats)
	}

	// Context expiry while still full surfaces the ctx error, not a silent drop.
	w.control <- laneRequest(`{"preloaded":"again"}`)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := w.enqueueOrWait(ctx, []byte(`{"cancel":3}`)); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("enqueueOrWait on persistently full lane = %v, want deadline exceeded", err)
	}
}

// TestEnqueueOrWaitOnDeadWriter reports stopped rather than blocking.
func TestEnqueueOrWaitOnDeadWriter(t *testing.T) {
	serverConn, _ := testWebSocketPair(t)
	w := newProviderWriter(serverConn)
	w.closeNow()
	<-w.done
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := w.enqueueOrWait(ctx, []byte(`{"cancel":1}`)); err != errProviderWriterStopped {
		t.Fatalf("enqueueOrWait on dead writer = %v, want stopped", err)
	}
}

// TestDrainCountsDroppedFireAndForgetFrames: control frames with no owner that
// are still queued at shutdown are counted, not silently discarded.
func TestDrainCountsDroppedFireAndForgetFrames(t *testing.T) {
	w := &providerWriter{
		queue:   make(chan *providerWriteRequest, 4),
		control: make(chan *providerWriteRequest, 4),
		done:    make(chan struct{}),
	}
	if err := w.enqueue(context.Background(), []byte(`{"cancel":1}`)); err != nil {
		t.Fatal(err)
	}
	if err := w.enqueue(context.Background(), []byte(`{"cancel":2}`)); err != nil {
		t.Fatal(err)
	}
	owned := &providerWriteRequest{data: []byte("owned"), done: make(chan error, 1)}
	w.control <- owned
	w.drainAll(errProviderWriterStopped)
	if err := <-owned.done; err != errProviderWriterStopped {
		t.Fatalf("owned frame error = %v", err)
	}
	stats := LinkStatsSnapshot{}
	w.fillLinkStats(&stats)
	if stats.DroppedOnClose != 2 {
		t.Fatalf("DroppedOnClose = %d, want 2", stats.DroppedOnClose)
	}
}

// TestLinkStatsCountersByLane checks outbound accounting per lane and the
// Provider-level join with inbound counters.
func TestLinkStatsCountersByLane(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	go func() {
		for {
			if _, _, err := clientConn.Read(context.Background()); err != nil {
				return
			}
		}
	}()
	p := &Provider{ID: "p1", writer: newProviderWriter(serverConn)}
	t.Cleanup(p.closeWriterNow)

	if err := p.WriteText(context.Background(), []byte(`{"data":1}`)); err != nil {
		t.Fatal(err)
	}
	if err := p.WriteTextControl(context.Background(), []byte(`{"ctl":1}`)); err != nil {
		t.Fatal(err)
	}
	if err := p.EnqueueText(context.Background(), []byte(`{"ctl":22}`)); err != nil {
		t.Fatal(err)
	}
	p.RecordInboundFrame("inference_response_chunk", 500)
	p.RecordInboundFrame("heartbeat", 2000)
	p.RecordInboundFrame("attestation_response", 300)

	deadline := time.Now().Add(2 * time.Second)
	var s LinkStatsSnapshot
	for {
		s = p.LinkStats()
		if s.ControlFramesOut == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("control frames never counted: %+v", s)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if s.DataFramesOut != 1 || s.DataBytesOut != uint64(len(`{"data":1}`)) {
		t.Fatalf("data counters = %+v", s)
	}
	if s.ControlBytesOut != uint64(len(`{"ctl":1}`)+len(`{"ctl":22}`)) {
		t.Fatalf("control bytes = %d", s.ControlBytesOut)
	}
	if s.FramesIn != 3 || s.BytesIn != 2800 || s.ChunkFramesIn != 1 || s.ChunkBytesIn != 500 ||
		s.HeartbeatFramesIn != 1 || s.HeartbeatBytesIn != 2000 ||
		s.OtherFramesIn != 1 || s.OtherBytesIn != 300 {
		t.Fatalf("inbound counters = %+v", s)
	}
	if s.DataQueueFull != 0 || s.ControlQueueFull != 0 || s.WriteTimeouts != 0 {
		t.Fatalf("unexpected error counters: %+v", s)
	}
}

func base64Of(b []byte) string {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	out := make([]byte, 0, len(b)*4/3+4)
	for i := 0; i < len(b); i += 3 {
		var n uint32
		rem := len(b) - i
		n = uint32(b[i]) << 16
		if rem > 1 {
			n |= uint32(b[i+1]) << 8
		}
		if rem > 2 {
			n |= uint32(b[i+2])
		}
		out = append(out, alphabet[n>>18&63], alphabet[n>>12&63])
		if rem > 1 {
			out = append(out, alphabet[n>>6&63])
		}
		if rem > 2 {
			out = append(out, alphabet[n&63])
		}
	}
	return string(out)
}

// TestLinkStatsSurviveWriterClose: once the writer is detached the outbound
// totals must still read back (frozen), never as zero — the metrics emitter
// diffs them and a zero would wrap into a negative rate.
func TestLinkStatsSurviveWriterClose(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	go func() {
		for {
			if _, _, err := clientConn.Read(context.Background()); err != nil {
				return
			}
		}
	}()
	p := &Provider{ID: "p-close", writer: newProviderWriter(serverConn)}
	if err := p.WriteText(context.Background(), []byte(`{"data":1}`)); err != nil {
		t.Fatal(err)
	}
	if err := p.WriteTextControl(context.Background(), []byte(`{"ctl":1}`)); err != nil {
		t.Fatal(err)
	}
	before := p.LinkStats()
	if before.DataFramesOut != 1 || before.ControlFramesOut != 1 {
		t.Fatalf("pre-close counters = %+v", before)
	}
	p.closeWriterNow()
	after := p.LinkStats()
	if after.DataFramesOut != 1 || after.DataBytesOut != before.DataBytesOut ||
		after.ControlFramesOut != 1 || after.ControlBytesOut != before.ControlBytesOut {
		t.Fatalf("counters after writer close = %+v, want frozen %+v", after, before)
	}
	if after.DataQueueDepth != 0 || after.ControlQueueDepth != 0 {
		t.Fatalf("queue depths after close = %+v", after)
	}
	if p.WriteInFlight() {
		t.Fatal("no writer: WriteInFlight must be false")
	}
}

// TestWriteInFlightTracksSocketWrite: a stalled data write (peer not reading)
// is visible as in-flight; an idle writer is not.
func TestWriteInFlightTracksSocketWrite(t *testing.T) {
	serverConn, _ := testWebSocketPair(t) // client never reads
	p := &Provider{ID: "p-inflight", writer: newProviderWriter(serverConn)}
	t.Cleanup(p.closeWriterNow)
	if p.WriteInFlight() {
		t.Fatal("idle writer reported in flight")
	}
	payload := bytes.Repeat([]byte("x"), 32<<20)
	go func() { _ = p.WriteText(context.Background(), payload) }()
	deadline := time.Now().Add(3 * time.Second)
	for !p.WriteInFlight() {
		if time.Now().After(deadline) {
			t.Fatal("stalled write never reported in flight")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestControlFallbackSlotsAreBounded: the per-connection fallback cap.
func TestControlFallbackSlotsAreBounded(t *testing.T) {
	p := &Provider{ID: "p-cap"}
	for i := 0; i < MaxControlFallbacksInFlight; i++ {
		if !p.TryAcquireControlFallback() {
			t.Fatalf("slot %d refused below the cap", i)
		}
	}
	if p.TryAcquireControlFallback() {
		t.Fatal("cap exceeded")
	}
	p.ReleaseControlFallback()
	if !p.TryAcquireControlFallback() {
		t.Fatal("released slot not reusable")
	}
	var nilP *Provider
	if nilP.TryAcquireControlFallback() {
		t.Fatal("nil provider must refuse")
	}
}

// TestDroppedOnCloseReachesRegistryTotals: frames drained at writer shutdown
// are counted registry-wide, because by then the connection has left the
// live map and the per-connection emitter can no longer diff them.
func TestDroppedOnCloseReachesRegistryTotals(t *testing.T) {
	serverConn, _ := testWebSocketPair(t) // client never reads
	var totals linkTotals
	w := newProviderWriterWithTotals(serverConn, &totals)
	// Stall the writer on a large data frame so control frames queue up.
	payload := bytes.Repeat([]byte("x"), 32<<20)
	go func() { _ = w.write(context.Background(), payload) }()
	deadline := time.Now().Add(3 * time.Second)
	for w.writeDeadline.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("write never started")
		}
		time.Sleep(5 * time.Millisecond)
	}
	for i := 0; i < 3; i++ {
		if err := w.enqueue(context.Background(), []byte(`{"type":"cancel"}`)); err != nil {
			t.Fatal(err)
		}
	}
	w.closeNow()
	select {
	case <-w.done:
	case <-time.After(5 * time.Second):
		t.Fatal("writer did not stop")
	}
	if got := totals.droppedOnClose.Load(); got != 3 {
		t.Fatalf("registry-wide droppedOnClose = %d, want 3", got)
	}
	stats := LinkStatsSnapshot{}
	w.fillLinkStats(&stats)
	if stats.DroppedOnClose != 3 {
		t.Fatalf("connection droppedOnClose = %d, want 3", stats.DroppedOnClose)
	}
}

// TestRunDrainsLanesOnWriteFailureExit: a writer that exits through a write
// failure (serve returns false) still answers queued owners and counts
// fire-and-forget frames instead of stranding them. Everything is queued
// before the goroutine starts so the test does not race its exit.
func TestRunDrainsLanesOnWriteFailureExit(t *testing.T) {
	var totals linkTotals
	w := &providerWriter{
		queue:   make(chan *providerWriteRequest, 4),
		control: make(chan *providerWriteRequest, 4),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
		totals:  &totals,
		writeFrameForTest: func([]byte) error {
			return errors.New("socket gone")
		},
	}
	// Control lane is served first: the owned frame fails the write, the
	// fire-and-forget cancel behind it must be drained and counted.
	failing := laneRequest(`{"first":true}`)
	failing.control = true
	w.control <- failing
	w.control <- &providerWriteRequest{ctx: context.Background(), data: []byte(`{"cancel":1}`), control: true}
	// Data lane: an owned frame that never gets its turn.
	late := laneRequest(`{"second":true}`)
	w.queue <- late

	go w.run()
	select {
	case err := <-failing.done:
		if err == nil {
			t.Fatal("first frame should have failed")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("first frame never settled")
	}
	select {
	case err := <-late.done:
		if err == nil {
			t.Fatal("queued owned frame should be failed on drain")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("queued owned frame was stranded")
	}
	select {
	case <-w.done:
	case <-time.After(3 * time.Second):
		t.Fatal("writer did not stop")
	}
	if got := totals.droppedOnClose.Load(); got != 1 {
		t.Fatalf("droppedOnClose = %d, want 1", got)
	}
}
