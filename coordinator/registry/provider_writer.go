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
	// full lane rejects a cancel — the one loss path on the coordinator side of
	// cancel delivery (provider.enqueue_failed{msg:cancel} then the blocking
	// fallback in api.sendProviderCancel).
	providerControlQueueSize      = 256
	providerWriteMinTimeout       = 5 * time.Second
	providerWriteMaxTimeout       = 30 * time.Second
	providerWriteBytesPerSecond   = 2 << 20 // 2 MiB/s (~16 Mbps) floor.
	providerControlWriteTimeout   = 5 * time.Second
	providerWriteWatchdogInterval = 250 * time.Millisecond
	providerWriteDrainErrorString = "provider websocket writer stopped"
	// providerWriteFragmentBytes is the payload size above which a data-lane
	// message is written as multiple WebSocket fragments instead of one frame.
	//
	// nhooyr holds the connection's frame mutex for the whole of a single-frame
	// write, and it answers the peer's pings from inside the read loop through
	// that same mutex with a fixed 5s budget. A multi-MiB sealed vision request
	// on a slow provider downlink therefore starved the pong for longer than 5s,
	// the library treated that as a fatal read error, and every in-flight
	// request on the connection was 502'd. Fragmenting releases the mutex
	// between fragments so control frames interleave (RFC 6455 §5.4 permits
	// control frames between fragments). Reassembly is transparent to the
	// provider: Network.framework delivers one complete message.
	providerWriteFragmentBytes = 64 << 10
)

var errProviderWriterStopped = errors.New(providerWriteDrainErrorString)
var errProviderWriterQueueFull = errors.New("provider websocket writer queue full")
var errProviderWriteTimeout = errors.New("provider websocket write timeout")

// Exported forms of the writer's sentinel errors so callers can classify a
// best-effort control-frame failure with errors.Is: ErrProviderWriterQueueFull
// is returned by the non-blocking send paths (EnqueueText, WriteText,
// WriteTextControl) when the target lane has no free slot, so a caller can
// choose a fallback instead of dropping the frame; ErrProviderWriterStopped
// means the writer (and its socket) is gone.
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
	// control records which lane the request was submitted on, for link
	// accounting only; lane membership itself is decided by the channel.
	control bool
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

	// link holds the outbound half of this connection's link counters
	// (frames/bytes per lane, queue-full rejections, timeouts, drops). The
	// inbound half lives on the owning Provider; see link_stats.go.
	link linkCounters
	// totals, when set, receives the teardown-time events (drops, timeouts)
	// that the per-connection counters cannot surface once the connection
	// has left the registry. Nil in tests that construct writers directly.
	totals *linkTotals

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
	return newProviderWriterWithTotals(conn, nil)
}

func newProviderWriterWithTotals(conn *websocket.Conn, totals *linkTotals) *providerWriter {
	if conn == nil {
		return nil
	}
	w := &providerWriter{
		conn:    conn,
		queue:   make(chan *providerWriteRequest, providerWriteQueueSize),
		control: make(chan *providerWriteRequest, providerControlQueueSize),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
		totals:  totals,
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
		if lane == w.control {
			w.link.controlQueueFull.Add(1)
		} else {
			w.link.dataQueueFull.Add(1)
		}
		return errProviderWriterQueueFull
	}
}

// submitBlocking is submit for callers that would rather wait for a slot than
// be rejected. It blocks until the lane accepts the request, ctx expires, or
// the writer stops. acceptMu is NOT held while waiting so closeNow can still
// mark the writer dead; the post-wait dead check keeps the "never enqueue on a
// dead writer" invariant that submit enforces under the mutex.
func (w *providerWriter) submitBlocking(ctx context.Context, lane chan *providerWriteRequest, req *providerWriteRequest) error {
	if lane == nil {
		return errProviderWriterQueueFull
	}
	if w.dead.Load() {
		return errProviderWriterStopped
	}
	select {
	case lane <- req:
		if w.dead.Load() {
			// The writer died while we were enqueuing; run's drain will publish
			// errProviderWriterStopped on req.done if anyone is waiting. Report
			// it here too so fire-and-forget callers learn the frame is lost.
			return errProviderWriterStopped
		}
		return nil
	case <-w.done:
		return errProviderWriterStopped
	case <-ctx.Done():
		return ctx.Err()
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
	req.control = control
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
		ctx:     context.Background(),
		data:    append([]byte(nil), data...),
		control: true,
	}
	return w.submit(w.control, req)
}

// enqueueOrWait is enqueue with a blocking fallback: when the control lane is
// full it waits (bounded by ctx) for a slot instead of rejecting the frame.
// Reports whether the fallback path was taken.
func (w *providerWriter) enqueueOrWait(ctx context.Context, data []byte) (fellBack bool, err error) {
	ctx, err = w.checkAccept(ctx)
	if err != nil {
		return false, err
	}
	req := &providerWriteRequest{
		ctx:     context.Background(),
		data:    append([]byte(nil), data...),
		control: true,
	}
	if err := w.submit(w.control, req); err != errProviderWriterQueueFull {
		return false, err
	}
	if err := w.submitBlocking(ctx, w.control, req); err != nil {
		return true, err
	}
	// Counted only once the frame actually landed on the lane; a fallback
	// that timed out is a drop, not a delivery.
	w.link.controlFallbacks.Add(1)
	return true, nil
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
	// Every exit path drains both lanes so queued owners are answered and
	// fire-and-forget frames are counted; the stop path drains explicitly
	// too, which is harmless on empty lanes. The writer is already dead
	// (closeNow) on every path that returns from serve, so no submit can
	// slip in behind the drain.
	defer w.drainAll(errProviderWriterStopped)
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
	if req.control {
		w.link.controlFramesOut.Add(1)
		w.link.controlBytesOut.Add(uint64(len(data)))
	} else {
		w.link.dataFramesOut.Add(1)
		w.link.dataBytesOut.Add(uint64(len(data)))
		if len(data) > providerWriteFragmentBytes {
			w.link.fragmentedFramesOut.Add(1)
		}
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
			} else {
				// Fire-and-forget frame with no owner to notify: count it so a
				// dropped cancel/trust_status is at least visible in metrics —
				// on the connection AND registry-wide, because this runs at
				// teardown after the connection has left the live map.
				w.link.droppedOnClose.Add(1)
				if w.totals != nil {
					w.totals.droppedOnClose.Add(1)
				}
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
	var err error
	if len(data) > providerWriteFragmentBytes {
		err = writeFragmented(w.conn, data, providerWriteFragmentBytes)
	} else {
		err = w.conn.Write(context.Background(), websocket.MessageText, data)
	}
	w.writeDeadline.Store(0)
	if err != nil && w.writeTimedOut.Load() {
		w.link.writeTimeouts.Add(1)
		if w.totals != nil {
			w.totals.writeTimeouts.Add(1)
		}
		return errProviderWriteTimeout
	}
	return err
}

// writeFragmented writes one text message as a sequence of WebSocket
// fragments of at most fragmentBytes each. nhooyr emits one frame per Write
// call on a message writer (first frame text, the rest continuation) and a
// final empty FIN frame on Close, releasing the connection's frame mutex
// between calls so interleaved control frames (pongs, close) get through.
func writeFragmented(conn *websocket.Conn, data []byte, fragmentBytes int) error {
	if fragmentBytes <= 0 {
		fragmentBytes = providerWriteFragmentBytes
	}
	wr, err := conn.Writer(context.Background(), websocket.MessageText)
	if err != nil {
		return err
	}
	for off := 0; off < len(data); off += fragmentBytes {
		end := off + fragmentBytes
		if end > len(data) {
			end = len(data)
		}
		if _, err := wr.Write(data[off:end]); err != nil {
			// nhooyr releases the message writer's mutex only on a
			// successful FIN write; after a mid-message failure Close fails
			// again and the mutex stays held, so this connection can never
			// carry another message. That is fine ONLY because serve()
			// closes the writer (and the socket) on any write error — do not
			// retry a failed frame on the same connection.
			_ = wr.Close()
			return err
		}
	}
	return wr.Close()
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

// EnqueueControlOrWait is EnqueueText with a blocking fallback. When the
// control lane has a free slot it behaves exactly like EnqueueText (queued,
// returns immediately). When the lane is full it waits — bounded by ctx — for
// a slot rather than rejecting the frame, so a burst of control traffic
// degrades to latency instead of a silently dropped cancel. fellBack reports
// whether the blocking path was taken so callers can meter it.
func (p *Provider) EnqueueControlOrWait(ctx context.Context, data []byte) (fellBack bool, err error) {
	if p == nil {
		return false, errors.New("provider is nil")
	}
	p.mu.Lock()
	w := p.writer
	p.mu.Unlock()
	if w == nil {
		return false, errProviderWriterStopped
	}
	return w.enqueueOrWait(ctx, data)
}

func (p *Provider) closeWriterNow() {
	if p == nil {
		return
	}
	p.mu.Lock()
	w := p.writer
	p.writer = nil
	p.mu.Unlock()
	if w == nil {
		return
	}
	w.closeNow()
	// Freeze the outbound counters on the provider so LinkStats keeps
	// reporting this connection's totals after the writer is gone. The
	// metrics emitter diffs per-connection totals; a provider caught between
	// "still in the registry map" and "writer detached" must not read back
	// as zero and produce a wrapped-around negative delta. Frozen AFTER
	// closeNow so the in-flight frame's completion is included; the drain
	// that follows on the writer goroutine reports its drops through
	// linkTotals instead (see drainLane).
	var final LinkStatsSnapshot
	w.fillLinkStats(&final)
	final.DataQueueDepth, final.ControlQueueDepth = 0, 0
	p.mu.Lock()
	p.link.finalOutbound = &final
	p.mu.Unlock()
}

// WriteInFlight reports whether the writer goroutine is currently inside a
// socket write (a data or control frame is being pushed to the kernel).
func (p *Provider) WriteInFlight() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	w := p.writer
	p.mu.Unlock()
	return w != nil && w.writeDeadline.Load() != 0
}
