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
	providerWriteQueueSize = 128
	// providerControlQueueSize bounds the priority lane. Its frames are tiny
	// (cancel / challenge / status, ~100 B) so the cost of depth is nil, while a
	// full lane silently drops a cancel — the one loss path on the coordinator
	// side of cancel delivery (inference.cancel_send_failed{reason:queue_full}).
	providerControlQueueSize    = 256
	providerWriteMinTimeout     = 5 * time.Second
	providerWriteMaxTimeout     = 30 * time.Second
	providerWriteBytesPerSecond = 2 << 20 // 2 MiB/s (~16 Mbps) floor.
	// providerWriteFragmentBytes is the WebSocket fragment size for data-lane
	// messages larger than one fragment. nhooyr answers peer pings on its READ
	// goroutine, under a 5s budget, and that pong needs the per-frame write
	// lock — so a message must never be one multi-second frame (see
	// writeFrame). 256 KiB keeps ~100 frames per 20 MiB vision request while
	// bounding the pong's wait to one fragment's wire time.
	providerWriteFragmentBytes    = 256 << 10
	providerControlWriteTimeout   = 5 * time.Second
	providerWriteWatchdogInterval = 250 * time.Millisecond
	providerWriteDrainErrorString = "provider websocket writer stopped"
)

var errProviderWriterStopped = errors.New(providerWriteDrainErrorString)
var errProviderWriterQueueFull = errors.New("provider websocket writer queue full")
var errProviderWriteTimeout = errors.New("provider websocket write timeout")

// Exported forms of the writer's sentinel errors so callers can classify a
// best-effort control-frame failure (cancel delivery metrics) with errors.Is.
var (
	ErrProviderWriterQueueFull = errProviderWriterQueueFull
	ErrProviderWriterStopped   = errProviderWriterStopped
)

// TextFrameWriteMetadata describes the writer-owned handoff of a deferred
// frame. The caller receives it synchronously and remains the sole owner of any
// request-state mutation derived from the handoff.
type TextFrameWriteMetadata struct {
	DequeuedAt time.Time
}

// TextFrameBuilder constructs a data-lane frame only after it reaches the head
// of the provider writer queue. Builders must be fast, side-effect-free, and
// capture only immutable state. dequeuedAt is the writer's monotonic timestamp
// for budget calculations and subsequent caller-owned timing attribution.
type TextFrameBuilder func(dequeuedAt time.Time) ([]byte, error)

// TextFrameHandoff runs synchronously on the submitting goroutine after the
// writer has built the frame and before it may expose bytes to the socket.
type TextFrameHandoff func(TextFrameWriteMetadata)

type providerWriteRequest struct {
	ctx        context.Context
	data       []byte
	builder    TextFrameBuilder
	done       chan error
	handoff    chan TextFrameWriteMetadata
	handoffAck chan struct{}
	// 0 queued, 1 canceled, 2 building, 3 awaiting owner ack, 4 writing,
	// 5 write completed.
	state atomic.Int32
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
//     model_commands.go go through WriteText). Rerouting those model commands to
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

	// writeDeadline is the UnixNano deadline of the in-flight socket write of
	// one whole message (0 = no write in progress). Published by writeFrame,
	// enforced by watchWrites.
	writeDeadline atomic.Int64
	// writeTimedOut records that the watchdog closed the socket due to a
	// write deadline, so writeFrame can surface a timeout error instead of
	// the generic connection-closed error.
	writeTimedOut atomic.Bool

	// timeoutFor overrides the per-frame write timeout in tests. Nil means
	// the default providerWriteTimeout schedule.
	timeoutFor func(frameBytes int) time.Duration
	// writeFrameForTest replaces the socket handoff in deterministic unit tests.
	writeFrameForTest func([]byte) error
	// afterWriteCompleteForTest pauses after the 4→5 ownership transition and
	// before publishing done, for deterministic completion/cancellation races.
	afterWriteCompleteForTest func()
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

func (w *providerWriter) writeDeferred(
	ctx context.Context,
	builder TextFrameBuilder,
	onHandoff TextFrameHandoff,
) (TextFrameWriteMetadata, error) {
	if builder == nil {
		return TextFrameWriteMetadata{}, errors.New("provider websocket frame builder is nil")
	}
	return w.writeRequest(ctx, &providerWriteRequest{builder: builder}, false, onHandoff)
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
	_, err := w.writeRequest(ctx, &providerWriteRequest{
		data: append([]byte(nil), data...),
	}, control, nil)
	return err
}

func (w *providerWriter) writeRequest(
	ctx context.Context,
	req *providerWriteRequest,
	control bool,
	onHandoff TextFrameHandoff,
) (TextFrameWriteMetadata, error) {
	var metadata TextFrameWriteMetadata
	ctx, err := w.checkAccept(ctx)
	if err != nil {
		return metadata, err
	}
	req.ctx = ctx
	req.done = make(chan error, 1)
	if req.builder != nil {
		req.handoff = make(chan TextFrameWriteMetadata, 1)
		req.handoffAck = make(chan struct{})
	}
	handoff := req.handoff
	handoffAck := req.handoffAck
	lane := w.queue
	if control {
		lane = w.control
	}
	if err := w.submit(lane, req); err != nil {
		return metadata, err
	}
	acceptHandoff := func(handedOff TextFrameWriteMetadata) {
		metadata = handedOff
		if !handedOff.DequeuedAt.IsZero() && onHandoff != nil {
			onHandoff(handedOff)
		}
		if handoffAck != nil {
			close(handoffAck)
			handoffAck = nil
		}
		handoff = nil
	}
	takeReadyHandoff := func() {
		if handoff == nil {
			return
		}
		select {
		case handedOff := <-handoff:
			acceptHandoff(handedOff)
		default:
		}
	}
	for {
		select {
		case handedOff := <-handoff:
			acceptHandoff(handedOff)
		case err := <-req.done:
			// Deferred terminal paths publish their handoff decision before
			// done. Drain it so select ordering cannot erase dequeue metadata.
			takeReadyHandoff()
			return metadata, err
		case <-ctx.Done():
			select {
			case err := <-req.done:
				takeReadyHandoff()
				return metadata, err
			default:
			}
			for {
				switch req.state.Load() {
				case 0:
					if !req.state.CompareAndSwap(0, 1) {
						continue
					}
					return metadata, ctx.Err()
				case 2:
					// Cancel a builder without waiting for it. Its immutable
					// snapshot may finish later, but the 2→3 handoff CAS will
					// fail and no frame can reach the socket.
					if !req.state.CompareAndSwap(2, 1) {
						continue
					}
					return metadata, ctx.Err()
				case 3:
					// The frame is waiting for the submitting owner to
					// acknowledge its timing metadata. Cancellation wins the
					// 3→4 transition, so no socket bytes can follow cleanup.
					if !req.state.CompareAndSwap(3, 1) {
						continue
					}
					return metadata, ctx.Err()
				case 4:
					// A frame is already in the non-preemptible WebSocket
					// write. Closing the connection is the only way to return
					// at the request deadline without letting that frame
					// outlive dispatch cleanup.
					if !req.state.CompareAndSwap(4, 1) {
						continue
					}
					w.closeNow()
					if handoff != nil {
						select {
						case handedOff := <-handoff:
							acceptHandoff(handedOff)
						case <-req.done:
							takeReadyHandoff()
						case <-w.done:
							takeReadyHandoff()
						}
					}
					return metadata, ctx.Err()
				case 5:
					// The complete frame is already on the wire. Keep the
					// healthy connection and report the authoritative write
					// result. Request-context cancellation is handled by the
					// dispatch owner after it takes ownership of the sent frame.
					return metadata, nil
				default:
					return metadata, ctx.Err()
				}
			}
		case <-w.done:
			takeReadyHandoff()
			return metadata, writeResultAfterWriterStop(ctx, req)
		}
	}
}

func writeResultAfterWriterStop(
	ctx context.Context,
	req *providerWriteRequest,
) error {
	// Writer shutdown may race the per-request completion publication. A
	// buffered request result is authoritative: in particular, a fully written
	// frame must not be reclassified as stopped and trigger cleanup/refunds.
	select {
	case err := <-req.done:
		return err
	default:
	}
	if req.state.Load() == 5 {
		return nil
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return errProviderWriterStopped
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

func (w *providerWriter) run() {
	defer w.dead.Store(true)
	defer close(w.done)
	watchdogStop := make(chan struct{})
	go w.watchWrites(watchdogStop)
	defer close(watchdogStop)
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
	startedState := int32(4)
	if req.builder != nil {
		startedState = 2
	}
	if (req.ctx != nil && req.ctx.Err() != nil) ||
		!req.state.CompareAndSwap(0, startedState) {
		if req.done != nil {
			if req.ctx != nil && req.ctx.Err() != nil {
				req.done <- req.ctx.Err()
			} else {
				req.done <- context.Canceled
			}
		}
		return true
	}
	data := req.data
	if req.builder != nil {
		dequeuedAt := time.Now()
		var err error
		data, err = req.builder(dequeuedAt)
		if err != nil {
			req.handoff <- TextFrameWriteMetadata{}
			if req.done != nil {
				req.done <- err
			}
			return true
		}
		// Atomically transfer the immutable frame from building to socket
		// handoff. Context cancellation can claim state 2 first, in which case
		// the builder is allowed to finish but its frame is discarded.
		if (req.ctx != nil && req.ctx.Err() != nil) ||
			!req.state.CompareAndSwap(2, 3) {
			req.handoff <- TextFrameWriteMetadata{}
			if req.done != nil {
				if req.ctx != nil && req.ctx.Err() != nil {
					req.done <- req.ctx.Err()
				} else {
					req.done <- context.Canceled
				}
			}
			return true
		}
		req.handoff <- TextFrameWriteMetadata{DequeuedAt: dequeuedAt}
		select {
		case <-req.handoffAck:
		case <-req.ctx.Done():
			req.state.CompareAndSwap(3, 1)
			if req.done != nil {
				req.done <- req.ctx.Err()
			}
			return true
		case <-w.stop:
			if req.done != nil {
				req.done <- errProviderWriterStopped
			}
			return false
		}
		if !req.state.CompareAndSwap(3, 4) {
			if req.done != nil {
				if req.ctx != nil && req.ctx.Err() != nil {
					req.done <- req.ctx.Err()
				} else {
					req.done <- context.Canceled
				}
			}
			return true
		}
	}
	writeFrame := w.writeFrame
	if w.writeFrameForTest != nil {
		writeFrame = w.writeFrameForTest
	}
	if err := writeFrame(data); err != nil {
		if req.done != nil {
			req.done <- err
		}
		w.closeNow()
		w.drainAll(err)
		return false
	}
	if !req.state.CompareAndSwap(4, 5) {
		// Cancellation won the write-completion race. Ensure the connection is
		// unusable before dispatch cleanup can release the request reservation.
		w.closeNow()
		if req.done != nil {
			if req.ctx != nil && req.ctx.Err() != nil {
				req.done <- req.ctx.Err()
			} else {
				req.done <- context.Canceled
			}
		}
		return false
	}
	if w.afterWriteCompleteForTest != nil {
		w.afterWriteCompleteForTest()
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
// deadline before the blocking socket write of a whole message and clears it
// after; when a deadline is exceeded the watchdog closes the socket, which
// unblocks the write with an error. Granularity is
// providerWriteWatchdogInterval, acceptable slack on a >=5s timeout floor.
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

// writeFrame puts one whole text message on the wire and returns only once
// its last frame has been handed to the socket.
//
// Messages larger than providerWriteFragmentBytes are sent as a fragmented
// WebSocket message (RFC 6455 §5.4) rather than one frame. nhooyr's
// Conn.Write holds the connection's per-frame write lock for the entire
// message, and its read goroutine answers the peer's pings inline — with a
// 5s budget to take that same lock. A single 20 MiB vision frame legitimately
// takes 10–30s at the write-timeout floor, so a provider ping (every 10s)
// landing mid-frame failed the pong, which nhooyr reports as a READ error
// ("failed to handle control frame opPing: ... failed to acquire lock"),
// tearing down the whole provider session and 502-ing every request on it.
// With msgWriter.Write the lock is held per fragment, so the pong interleaves
// between continuation frames; the receiver reassembles into one message.
func (w *providerWriter) writeFrame(data []byte) error {
	// Do not pass a cancelable/expiring context to nhooyr's Write/Writer:
	// context expiration is treated as a connection-level failure by the
	// library. The writer owns timeout/backpressure externally (watchWrites,
	// one deadline for the whole message) and closes unhealthy sockets
	// explicitly with CloseNow.
	timeout := providerWriteTimeout(len(data))
	if w.timeoutFor != nil {
		timeout = w.timeoutFor(len(data))
	}
	w.writeDeadline.Store(time.Now().Add(timeout).UnixNano())
	err := writeFragmented(w.conn, data)
	w.writeDeadline.Store(0)
	if err != nil && w.writeTimedOut.Load() {
		return errProviderWriteTimeout
	}
	return err
}

// writeFragmented sends data as one text message: a single frame when it
// fits in providerWriteFragmentBytes, otherwise ceil(n/fragment) non-FIN
// frames of at most fragment bytes followed by nhooyr's zero-length FIN
// continuation. A mid-message write error is returned as-is without
// attempting the FIN frame; the caller closes the socket on any error, which
// is also what makes nhooyr's unreleased message-writer lock irrelevant.
func writeFragmented(conn *websocket.Conn, data []byte) error {
	if len(data) <= providerWriteFragmentBytes {
		return conn.Write(context.Background(), websocket.MessageText, data)
	}
	mw, err := conn.Writer(context.Background(), websocket.MessageText)
	if err != nil {
		return err
	}
	for off := 0; off < len(data); off += providerWriteFragmentBytes {
		end := min(off+providerWriteFragmentBytes, len(data))
		if _, err := mw.Write(data[off:end]); err != nil {
			return err
		}
	}
	return mw.Close()
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

// WriteTextDeferred serializes a data-lane frame whose bytes are constructed at
// dequeue time, immediately before socket handoff. It preserves the same FIFO,
// strict control-lane priority, and non-preemptible in-flight write semantics as
// WriteText. onHandoff runs on the caller before socket exposure.
func (p *Provider) WriteTextDeferred(
	ctx context.Context,
	builder TextFrameBuilder,
	onHandoff TextFrameHandoff,
) (TextFrameWriteMetadata, error) {
	if p == nil {
		return TextFrameWriteMetadata{}, errors.New("provider is nil")
	}
	p.mu.Lock()
	w := p.writer
	p.mu.Unlock()
	if w == nil {
		return TextFrameWriteMetadata{}, errProviderWriterStopped
	}
	return w.writeDeferred(ctx, builder, onHandoff)
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
