package registry

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/registry/providerwriter"
	"nhooyr.io/websocket"
)

const providerControlWriteTimeout = providerwriter.ControlWriteTimeout

var errProviderWriterStopped = providerwriter.ErrStopped

// Sentinel aliases preserve cancellation failure classification at API callers.
var (
	ErrProviderWriterQueueFull = providerwriter.ErrQueueFull
	ErrProviderWriterStopped   = providerwriter.ErrStopped
)

type TextFrameWriteMetadata = providerwriter.TextFrameWriteMetadata
type TextFrameBuilder = providerwriter.TextFrameBuilder
type TextFrameHandoff = providerwriter.TextFrameHandoff

func newProviderWriter(conn *websocket.Conn) *providerwriter.Writer { return providerwriter.New(conn) }

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
	return w.Write(ctx, data)
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
	return w.WriteDeferred(ctx, builder, onHandoff)
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
	return w.WriteControl(ctx, data)
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
	return w.Enqueue(ctx, data)
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
		w.CloseNow()
	}
}
