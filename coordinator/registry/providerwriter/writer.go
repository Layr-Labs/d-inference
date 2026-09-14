package providerwriter

import (
	"sync"
	"sync/atomic"
	"time"

	"nhooyr.io/websocket"
)

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
	conn     *websocket.Conn
	queue    chan *writeRequest
	control  chan *writeRequest
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
	// the default writeTimeout schedule.
	timeoutFor func(frameBytes int) time.Duration
	// writeFrameForTest replaces the socket handoff in deterministic unit tests.
	writeFrameForTest func([]byte) error
	// afterWriteCompleteForTest pauses after the 4→5 ownership transition and
	// before publishing done, for deterministic completion/cancellation races.
	afterWriteCompleteForTest func()
}

func New(conn *websocket.Conn) *Writer {
	if conn == nil {
		return nil
	}
	w := &Writer{
		conn:    conn,
		queue:   make(chan *writeRequest, dataQueueSize),
		control: make(chan *writeRequest, controlQueueSize),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	go w.run()
	return w
}

func (w *Writer) CloseNow() {
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
