package providerwrite

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/writertransport"
	"nhooyr.io/websocket"
)

const (
	DataQueueSize = 128
	// ControlQueueSize bounds the priority lane. Its frames are tiny
	// (cancel / challenge / status, ~100 B) so the cost of depth is nil, while a
	// full lane silently drops a cancel — the one loss path on the coordinator
	// side of cancel delivery (inference.cancel_send_failed{reason:queue_full}).
	ControlQueueSize              = 256
	ControlWriteTimeout           = 5 * time.Second
	providerWriteDrainErrorString = "provider websocket writer stopped"
)

var ErrStopped = errors.New(providerWriteDrainErrorString)
var ErrQueueFull = errors.New("provider websocket writer queue full")
var ErrTimeout = writertransport.ErrTimeout

// Writer serializes all writes to one provider WebSocket through a
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
type Writer struct {
	transport Transport
	lanes     *Lanes
	stop      chan struct{}
	done      chan struct{}
	acceptMu  sync.Mutex
	dead      atomic.Bool
}

// New retains the transport and bounded mailboxes. The owner starts Run after
// it has published the connection binding, and closes the same writer on retire.
func New(transport Transport, lanes *Lanes) *Writer {
	if lanes == nil {
		lanes = NewLanes(DataQueueSize, ControlQueueSize)
	}
	return &Writer{transport: transport, lanes: lanes, stop: make(chan struct{}), done: make(chan struct{})}
}

func NewSocket(conn *websocket.Conn) *Writer {
	if conn == nil {
		return nil
	}
	w := New(NewSocketTransport(conn, nil), nil)
	go w.Run()
	return w
}

// submit excludes connection shutdown while offering a frame to its mailbox.
func (w *Writer) submit(req *Request, control bool) error {
	w.acceptMu.Lock()
	if w.Closed() {
		w.acceptMu.Unlock()
		return ErrStopped
	}
	err := w.lanes.Offer(req, control, w.done)
	w.acceptMu.Unlock()
	return err
}

func (w *Writer) Write(ctx context.Context, data []byte) error {
	return w.writeLane(ctx, data, false)
}

func (w *Writer) WriteDeferred(
	ctx context.Context,
	builder Builder,
	onHandoff Handoff,
) (Metadata, error) {
	if builder == nil {
		return Metadata{}, errors.New("provider websocket frame builder is nil")
	}
	return w.WriteRequest(ctx, NewDeferred(builder, nil), false, onHandoff)
}

// writeControl is write() on the priority control lane.
func (w *Writer) WriteControl(ctx context.Context, data []byte) error {
	return w.writeLane(ctx, data, true)
}

// checkAccept validates the shared submission preamble: writer liveness
// (nil/dead) and caller-context expiry. It normalizes a nil ctx to
// context.Background() and returns the ctx to use, or a non-nil error when
// the frame must be rejected.
func (w *Writer) checkAccept(ctx context.Context) (context.Context, error) {
	if w == nil {
		return nil, ErrStopped
	}
	if w.Closed() {
		return nil, ErrStopped
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return ctx, nil
}

func (w *Writer) writeLane(ctx context.Context, data []byte, control bool) error {
	_, err := w.WriteRequest(ctx, NewFrame(data, nil), control, nil)
	return err
}

// enqueue queues a control-plane frame fire-and-forget on the priority lane.
func (w *Writer) Enqueue(ctx context.Context, data []byte) error {
	if _, err := w.checkAccept(ctx); err != nil {
		return err
	}
	req := &Request{
		ctx:  context.Background(),
		data: append([]byte(nil), data...),
	}
	return w.submit(req, true)
}

func (w *Writer) Close() {
	if w == nil {
		return
	}
	w.acceptMu.Lock()
	if !w.dead.CompareAndSwap(false, true) {
		w.acceptMu.Unlock()
		return
	}
	close(w.stop)
	if w.transport != nil {
		w.transport.Close()
	}
	w.acceptMu.Unlock()
}

func (w *Writer) Run() {
	defer w.dead.Store(true)
	defer close(w.done)
	watchdogStop := make(chan struct{})
	if w.transport != nil {
		go w.transport.Watch(watchdogStop, w.stop)
	}
	defer close(watchdogStop)
	for {
		// Strict priority: serve any waiting control frame before data.
		select {
		case <-w.stop:
			w.drainAll(ErrStopped)
			return
		case req := <-w.lanes.Receive(true):
			if !w.serve(req) {
				return
			}
			continue
		default:
		}
		select {
		case <-w.stop:
			w.drainAll(ErrStopped)
			return
		case req := <-w.lanes.Receive(true):
			if !w.serve(req) {
				return
			}
		case req := <-w.lanes.Receive(false):
			if !w.serve(req) {
				return
			}
		}
	}
}

func (w *Writer) drainAll(err error) {
	w.drainLane(w.lanes.control, err)
	w.drainLane(w.lanes.data, err)
}

func (w *Writer) drainLane(lane chan *Request, err error) {
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

func (w *Writer) Closed() bool          { return w.dead.Load() }
func (w *Writer) Done() <-chan struct{} { return w.done }
