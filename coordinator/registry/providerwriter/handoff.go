package providerwriter

import (
	"context"
	"sync/atomic"
	"time"
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

type writeRequest struct {
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

func (w *Writer) writeRequest(
	ctx context.Context,
	req *writeRequest,
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
					w.CloseNow()
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
	req *writeRequest,
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
	return errStopped
}
