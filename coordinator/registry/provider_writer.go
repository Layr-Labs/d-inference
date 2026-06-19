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
	providerWriteMinTimeout       = 5 * time.Second
	providerWriteMaxTimeout       = 30 * time.Second
	providerWriteBytesPerSecond   = 2 << 20 // 2 MiB/s (~16 Mbps) floor.
	providerControlWriteTimeout   = 5 * time.Second
	providerWriteDrainErrorString = "provider websocket writer stopped"
)

var errProviderWriterStopped = errors.New(providerWriteDrainErrorString)
var errProviderWriterQueueFull = errors.New("provider websocket writer queue full")

type providerWriteRequest struct {
	ctx   context.Context
	data  []byte
	done  chan error
	state atomic.Int32 // 0 queued, 1 canceled before start, 2 started
}

type providerWriter struct {
	conn     *websocket.Conn
	queue    chan *providerWriteRequest
	stop     chan struct{}
	done     chan struct{}
	acceptMu sync.Mutex
	dead     atomic.Bool
}

func newProviderWriter(conn *websocket.Conn) *providerWriter {
	if conn == nil {
		return nil
	}
	w := &providerWriter{
		conn:  conn,
		queue: make(chan *providerWriteRequest, providerWriteQueueSize),
		stop:  make(chan struct{}),
		done:  make(chan struct{}),
	}
	go w.run()
	return w
}

func (w *providerWriter) write(ctx context.Context, data []byte) error {
	if w == nil {
		return errProviderWriterStopped
	}
	if w.dead.Load() {
		return errProviderWriterStopped
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	req := &providerWriteRequest{
		ctx:  ctx,
		data: append([]byte(nil), data...),
		done: make(chan error, 1),
	}
	w.acceptMu.Lock()
	if w.dead.Load() {
		w.acceptMu.Unlock()
		return errProviderWriterStopped
	}
	select {
	case w.queue <- req:
		w.acceptMu.Unlock()
	case <-w.done:
		w.acceptMu.Unlock()
		return errProviderWriterStopped
	default:
		w.acceptMu.Unlock()
		return errProviderWriterQueueFull
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

func (w *providerWriter) enqueue(ctx context.Context, data []byte) error {
	if w == nil {
		return errProviderWriterStopped
	}
	if w.dead.Load() {
		return errProviderWriterStopped
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	req := &providerWriteRequest{
		ctx:  context.Background(),
		data: append([]byte(nil), data...),
	}
	w.acceptMu.Lock()
	if w.dead.Load() {
		w.acceptMu.Unlock()
		return errProviderWriterStopped
	}
	select {
	case w.queue <- req:
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
	for {
		select {
		case <-w.stop:
			w.drain(errProviderWriterStopped)
			return
		case req := <-w.queue:
			if (req.ctx != nil && req.ctx.Err() != nil) || !req.state.CompareAndSwap(0, 2) {
				if req.done != nil {
					if req.ctx != nil && req.ctx.Err() != nil {
						req.done <- req.ctx.Err()
					} else {
						req.done <- context.Canceled
					}
				}
				continue
			}
			if err := w.writeFrame(req.data); err != nil {
				if req.done != nil {
					req.done <- err
				}
				w.closeNow()
				w.drain(err)
				return
			}
			if req.done != nil {
				req.done <- nil
			}
		}
	}
}

func (w *providerWriter) drain(err error) {
	for {
		select {
		case req := <-w.queue:
			if req.done != nil {
				req.done <- err
			}
		default:
			return
		}
	}
}

func (w *providerWriter) writeFrame(data []byte) error {
	done := make(chan error, 1)
	go func() {
		// Do not pass a cancelable/expiring context to nhooyr.Conn.Write: context
		// expiration is treated as a connection-level failure by the library. The
		// writer owns timeout/backpressure externally and closes unhealthy sockets
		// explicitly with CloseNow.
		done <- w.conn.Write(context.Background(), websocket.MessageText, data)
	}()
	timer := time.NewTimer(providerWriteTimeout(len(data)))
	defer timer.Stop()
	select {
	case err := <-done:
		return err
	case <-timer.C:
		if w.conn != nil {
			_ = w.conn.CloseNow()
		}
		return errors.New("provider websocket write timeout")
	case <-w.stop:
		if w.conn != nil {
			_ = w.conn.CloseNow()
		}
		return errProviderWriterStopped
	}
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
// writer. ctx controls enqueue/result waiting only; it is never passed to the
// underlying WebSocket write.
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

// EnqueueText queues a text WebSocket frame without waiting for write
// completion. It is for control-plane best-effort sends (cancel/load/prefetch/
// status) where a caller must not block behind prior data frames. ctx controls
// enqueue only; it is never passed to the underlying WebSocket write.
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
