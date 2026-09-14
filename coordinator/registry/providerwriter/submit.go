package providerwriter

import (
	"context"
	"errors"
)

// submit enqueues a request on the given lane without blocking. A nil lane
// (writers constructed directly in tests) behaves as a full queue.
func (w *Writer) submit(lane chan *writeRequest, req *writeRequest) error {
	w.acceptMu.Lock()
	if w.dead.Load() {
		w.acceptMu.Unlock()
		return errStopped
	}
	select {
	case lane <- req:
		w.acceptMu.Unlock()
		return nil
	case <-w.done:
		w.acceptMu.Unlock()
		return errStopped
	default:
		w.acceptMu.Unlock()
		return errQueueFull
	}
}

func (w *Writer) Write(ctx context.Context, data []byte) error {
	return w.writeLane(ctx, data, false)
}

func (w *Writer) WriteDeferred(
	ctx context.Context,
	builder TextFrameBuilder,
	onHandoff TextFrameHandoff,
) (TextFrameWriteMetadata, error) {
	if builder == nil {
		return TextFrameWriteMetadata{}, errors.New("provider websocket frame builder is nil")
	}
	return w.writeRequest(ctx, &writeRequest{builder: builder}, false, onHandoff)
}

// WriteControl is write() on the priority control lane.
func (w *Writer) WriteControl(ctx context.Context, data []byte) error {
	return w.writeLane(ctx, data, true)
}

// checkAccept validates the shared submission preamble: writer liveness
// (nil/dead) and caller-context expiry. It normalizes a nil ctx to
// context.Background() and returns the ctx to use, or a non-nil error when
// the frame must be rejected.
func (w *Writer) checkAccept(ctx context.Context) (context.Context, error) {
	if w == nil {
		return nil, errStopped
	}
	if w.dead.Load() {
		return nil, errStopped
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
	_, err := w.writeRequest(ctx, &writeRequest{
		data: append([]byte(nil), data...),
	}, control, nil)
	return err
}

// Enqueue queues a control-plane frame fire-and-forget on the priority lane.
func (w *Writer) Enqueue(ctx context.Context, data []byte) error {
	if _, err := w.checkAccept(ctx); err != nil {
		return err
	}
	req := &writeRequest{
		ctx:  context.Background(),
		data: append([]byte(nil), data...),
	}
	return w.submit(w.control, req)
}
