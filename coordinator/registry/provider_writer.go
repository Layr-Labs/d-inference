package registry

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"nhooyr.io/websocket"
)

const (
	providerWriteQueueSize        = 128
	providerControlQueueSize      = 64
	providerWriteMinTimeout       = 5 * time.Second
	providerWriteMaxTimeout       = 30 * time.Second
	providerWriteBytesPerSecond   = 2 << 20 // 2 MiB/s (~16 Mbps) floor.
	providerControlWriteTimeout   = 5 * time.Second
	providerWriteWatchdogInterval = 250 * time.Millisecond
	providerWriteDrainErrorString = "provider websocket writer stopped"
)

var errProviderWriterStopped = errors.New(providerWriteDrainErrorString)
var errProviderWriterQueueFull = errors.New("provider websocket writer queue full")
var errProviderWriteTimeout = errors.New("provider websocket write timeout")

type providerWriteRequest struct {
	ctx   context.Context
	data  []byte
	done  chan error
	state atomic.Int32 // 0 queued, 1 canceled before start, 2 started
}

// providerWriter serializes all writes to one provider WebSocket through a
// single goroutine, with two lanes:
//
//   - control: small latency-sensitive frames — attestation challenges
//     (WriteTextControl, api/provider.go) and cancel / trust-status /
//     runtime-status frames (EnqueueText). Served with strict priority so
//     they do not queue behind backlogged multi-MiB inference frames — a
//     congested data lane must not convert into attestation timeouts or
//     delayed cancels that burn provider GPU.
//   - queue: data frames — inference request bodies (up to ~21 MiB sealed
//     vision payloads) AND the load_model / prefetch_model / desired_models
//     commands (SendLoadModel, SendPrefetchModel, SendDesiredModels in
//     registry.go go through WriteText). Rerouting those model commands to
//     the control lane is a candidate follow-up; today they share the data
//     lane.
//
// Ordering: frames are FIFO only WITHIN a lane; ordering ACROSS lanes is
// unspecified — a control frame submitted after a data frame may reach the
// wire first. Priority is non-preemptive: a control frame still waits for
// any in-flight data write to finish (up to the per-frame write timeout,
// 30s worst case) before it is served.
//
// Per-frame write deadlines are enforced by a single watchdog goroutine per
// connection (see watchWrites) rather than a goroutine+timer per frame.
type providerWriter struct {
	conn     *websocket.Conn
	queue    chan *providerWriteRequest
	control  chan *providerWriteRequest
	stop     chan struct{}
	done     chan struct{}
	acceptMu sync.Mutex
	dead     atomic.Bool

	// writeDeadline is the UnixNano deadline of the in-flight conn.Write
	// (0 = no write in progress). Published by writeFrame, enforced by
	// watchWrites.
	writeDeadline atomic.Int64
	// writeTimedOut records that the watchdog closed the socket due to a
	// write deadline, so writeFrame can surface a timeout error instead of
	// the generic connection-closed error.
	writeTimedOut atomic.Bool

	// timeoutFor overrides the per-frame write timeout in tests. Nil means
	// the default providerWriteTimeout schedule.
	timeoutFor func(frameBytes int) time.Duration
}

func newProviderWriter(conn *websocket.Conn) *providerWriter {
	if conn == nil {
		return nil
	}
	w := &providerWriter{
		conn:    conn,
		queue:   make(chan *providerWriteRequest, providerWriteQueueSize),
		control: make(chan *providerWriteRequest, providerControlQueueSize),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	go w.run()
	return w
}

// submit enqueues a request on the given lane without blocking. A nil lane
// (writers constructed directly in tests) behaves as a full queue.
func (w *providerWriter) submit(lane chan *providerWriteRequest, req *providerWriteRequest) error {
	w.acceptMu.Lock()
	if w.dead.Load() {
		w.acceptMu.Unlock()
		return errProviderWriterStopped
	}
	select {
	case lane <- req:
		w.acceptMu.Unlock()
		return nil
	case <-w.done:
		w.acceptMu.Unlock()
		return errProviderWriterStopped
	default:
		w.acceptMu.Unlock()
		return errProviderWriterQueueFull
	}
}

func (w *providerWriter) write(ctx context.Context, data []byte) error {
	return w.writeLane(ctx, data, false)
}

// writeControl is write() on the priority control lane.
func (w *providerWriter) writeControl(ctx context.Context, data []byte) error {
	return w.writeLane(ctx, data, true)
}

// checkAccept validates the shared submission preamble: writer liveness
// (nil/dead) and caller-context expiry. It normalizes a nil ctx to
// context.Background() and returns the ctx to use, or a non-nil error when
// the frame must be rejected.
func (w *providerWriter) checkAccept(ctx context.Context) (context.Context, error) {
	if w == nil {
		return nil, errProviderWriterStopped
	}
	if w.dead.Load() {
		return nil, errProviderWriterStopped
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return ctx, nil
}

func (w *providerWriter) writeLane(ctx context.Context, data []byte, control bool) error {
	ctx, err := w.checkAccept(ctx)
	if err != nil {
		return err
	}
	req := &providerWriteRequest{
		ctx:  ctx,
		data: append([]byte(nil), data...),
		done: make(chan error, 1),
	}
	lane := w.queue
	if control {
		lane = w.control
	}
	if err := w.submit(lane, req); err != nil {
		return err
	}
	select {
	case err := <-req.done:
		return err
	case <-ctx.Done():
		if req.state.CompareAndSwap(0, 1) {
			return ctx.Err()
		}
		select {
		case err := <-req.done:
			return err
		case <-w.done:
			return errProviderWriterStopped
		}
	case <-w.done:
		return errProviderWriterStopped
	}
}

// enqueue queues a control-plane frame fire-and-forget on the priority lane.
func (w *providerWriter) enqueue(ctx context.Context, data []byte) error {
	if _, err := w.checkAccept(ctx); err != nil {
		return err
	}
	req := &providerWriteRequest{
		ctx:  context.Background(),
		data: append([]byte(nil), data...),
	}
	return w.submit(w.control, req)
}

func (w *providerWriter) closeNow() {
	if w == nil {
		return
	}
	w.acceptMu.Lock()
	if !w.dead.CompareAndSwap(false, true) {
		w.acceptMu.Unlock()
		return
	}
	close(w.stop)
	if w.conn != nil {
		_ = w.conn.CloseNow()
	}
	w.acceptMu.Unlock()
}

func (w *providerWriter) closeAndWait(ctx context.Context) bool {
	if w == nil {
		return true
	}
	w.closeNow()
	select {
	case <-w.done:
		return true
	case <-ctx.Done():
		return false
	}
}

func (w *providerWriter) run() {
	defer w.dead.Store(true)
	defer close(w.done)
	watchdogStop := make(chan struct{})
	watchdogDone := make(chan struct{})
	go func() {
		defer close(watchdogDone)
		w.watchWrites(watchdogStop)
	}()
	defer func() {
		close(watchdogStop)
		<-watchdogDone
	}()
	for {
		// Strict priority: serve any waiting control frame before data.
		select {
		case <-w.stop:
			w.drainAll(errProviderWriterStopped)
			return
		case req := <-w.control:
			if !w.serve(req) {
				return
			}
			continue
		default:
		}
		select {
		case <-w.stop:
			w.drainAll(errProviderWriterStopped)
			return
		case req := <-w.control:
			if !w.serve(req) {
				return
			}
		case req := <-w.queue:
			if !w.serve(req) {
				return
			}
		}
	}
}

// serve writes one queued frame. It returns false when the writer must exit
// (write failure): the socket is closed and both lanes are drained first.
func (w *providerWriter) serve(req *providerWriteRequest) bool {
	if (req.ctx != nil && req.ctx.Err() != nil) || !req.state.CompareAndSwap(0, 2) {
		if req.done != nil {
			if req.ctx != nil && req.ctx.Err() != nil {
				req.done <- req.ctx.Err()
			} else {
				req.done <- context.Canceled
			}
		}
		return true
	}
	if err := w.writeFrame(req.data); err != nil {
		if req.done != nil {
			req.done <- err
		}
		w.closeNow()
		w.drainAll(err)
		return false
	}
	if req.done != nil {
		req.done <- nil
	}
	return true
}

func (w *providerWriter) drainAll(err error) {
	w.drainLane(w.control, err)
	w.drainLane(w.queue, err)
}

func (w *providerWriter) drainLane(lane chan *providerWriteRequest, err error) {
	for {
		select {
		case req := <-lane:
			if req.done != nil {
				req.done <- err
			}
		default:
			return
		}
	}
}

// watchWrites enforces per-frame write deadlines with one goroutine per
// connection instead of a goroutine+timer per frame. writeFrame publishes its
// deadline before the blocking conn.Write and clears it after; when a deadline
// is exceeded the watchdog closes the socket, which unblocks Write with an
// error. Granularity is providerWriteWatchdogInterval, acceptable slack on a
// >=5s timeout floor.
func (w *providerWriter) watchWrites(stop <-chan struct{}) {
	ticker := time.NewTicker(providerWriteWatchdogInterval)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-w.stop:
			return
		case <-ticker.C:
			d := w.writeDeadline.Load()
			if d != 0 && time.Now().UnixNano() > d {
				w.writeTimedOut.Store(true)
				if w.conn != nil {
					_ = w.conn.CloseNow()
				}
				return
			}
		}
	}
}

func (w *providerWriter) writeFrame(data []byte) error {
	// Do not pass a cancelable/expiring context to nhooyr.Conn.Write: context
	// expiration is treated as a connection-level failure by the library. The
	// writer owns timeout/backpressure externally (watchWrites) and closes
	// unhealthy sockets explicitly with CloseNow.
	timeout := providerWriteTimeout(len(data))
	if w.timeoutFor != nil {
		timeout = w.timeoutFor(len(data))
	}
	w.writeDeadline.Store(time.Now().Add(timeout).UnixNano())
	err := w.conn.Write(context.Background(), websocket.MessageText, data)
	w.writeDeadline.Store(0)
	if err != nil && w.writeTimedOut.Load() {
		return errProviderWriteTimeout
	}
	return err
}

func providerWriteTimeout(frameBytes int) time.Duration {
	if frameBytes <= 0 {
		return providerWriteMinTimeout
	}
	d := time.Duration(frameBytes) * time.Second / providerWriteBytesPerSecond
	if d < providerWriteMinTimeout {
		return providerWriteMinTimeout
	}
	if d > providerWriteMaxTimeout {
		return providerWriteMaxTimeout
	}
	return d
}

// WriteText serializes a text WebSocket frame through this provider's single
// writer (data lane). ctx controls enqueue/result waiting only; it is never
// passed to the underlying WebSocket write.
//
// WriteText returns only after the frame has been written to the socket (or
// the write failed). This synchronous completion is the invariant that keeps
// request→cancel ordering correct at call sites: a cancel enqueued on the
// control lane AFTER WriteText returned can never precede the request on the
// wire. Cross-lane ordering is otherwise unspecified.
func (p *Provider) WriteText(ctx context.Context, data []byte) error {
	if p == nil {
		return errors.New("provider is nil")
	}
	p.mu.Lock()
	w := p.writer
	p.mu.Unlock()
	if w == nil {
		return errProviderWriterStopped
	}
	return w.write(ctx, data)
}

// WriteTextControl is WriteText on the priority control lane. Use it for
// small latency-sensitive frames (attestation challenges) that must not queue
// behind backlogged data frames. Control frames may overtake data frames
// still queued on the data lane; priority is non-preemptive, so an in-flight
// data write completes first (up to the per-frame write timeout).
func (p *Provider) WriteTextControl(ctx context.Context, data []byte) error {
	if p == nil {
		return errors.New("provider is nil")
	}
	p.mu.Lock()
	w := p.writer
	p.mu.Unlock()
	if w == nil {
		return errProviderWriterStopped
	}
	return w.writeControl(ctx, data)
}

// EnqueueText queues a text WebSocket frame without waiting for write
// completion, on the priority control lane. It is for control-plane
// best-effort sends (cancel / trust-status / runtime-status) where a caller
// must not block behind prior data frames; the frame may overtake data
// frames still queued on the data lane. ctx controls enqueue only; it is
// never passed to the underlying WebSocket write.
func (p *Provider) EnqueueText(ctx context.Context, data []byte) error {
	if p == nil {
		return errors.New("provider is nil")
	}
	p.mu.Lock()
	w := p.writer
	p.mu.Unlock()
	if w == nil {
		return errProviderWriterStopped
	}
	return w.enqueue(ctx, data)
}

func (p *Provider) closeWriterNow() {
	if p == nil {
		return
	}
	p.mu.Lock()
	w := p.writer
	p.writer = nil
	p.mu.Unlock()
	if w != nil {
		w.closeNow()
	}
}

func (p *Provider) closeWriterAndWait(ctx context.Context) bool {
	if p == nil {
		return true
	}
	p.mu.Lock()
	w := p.writer
	p.writer = nil
	p.mu.Unlock()
	return w.closeAndWait(ctx)
}
