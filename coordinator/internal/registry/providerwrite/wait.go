package providerwrite

import (
	"context"
)

func (w *Writer) WriteRequest(
	ctx context.Context,
	req *Request,
	control bool,
	onHandoff Handoff,
) (metadata Metadata, resultErr error) {
	// State, rather than error==nil or prepared metadata, is authoritative.
	// In-flight/completed/canceled-in-flight can only follow final authorization;
	// canceled preparations and rejected frames never become dispatched attempts.
	defer func() {
		switch req.state.Load() {
		case providerWriteInFlight, providerWriteCompleted, providerWriteCanceledInFlight:
			metadata.Committed = true
		}
	}()
	ctx, err := w.checkAccept(ctx)
	if err != nil {
		return metadata, err
	}
	req.ctx = ctx
	if req.done == nil {
		req.done = make(chan error, 1)
	}
	if req.builder != nil {
		req.handoff = make(chan Metadata, 1)
		req.handoffAck = make(chan struct{})
	}
	handoff := req.handoff
	handoffAck := req.handoffAck
	if err := w.submit(req, control); err != nil {
		return metadata, err
	}
	acceptHandoff := func(handedOff Metadata) {
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
				case providerWriteQueued:
					if !req.state.CompareAndSwap(providerWriteQueued, providerWriteCanceledBeforeHandoff) {
						continue
					}
					return metadata, ctx.Err()
				case providerWriteBuilding:
					// Cancel a builder without waiting for it. Its immutable
					// snapshot may finish later, but the 2→3 handoff CAS will
					// fail and no frame can reach the socket.
					if !req.state.CompareAndSwap(providerWriteBuilding, providerWriteCanceledBeforeHandoff) {
						continue
					}
					return metadata, ctx.Err()
				case providerWriteAwaitingOwner:
					// The frame is waiting for the submitting owner to
					// acknowledge its timing metadata. Cancellation wins the
					// 3→7 transition, so no socket bytes can follow cleanup.
					if !req.state.CompareAndSwap(providerWriteAwaitingOwner, providerWriteCanceledBeforeHandoff) {
						continue
					}
					return metadata, ctx.Err()
				case providerWriteInFlight:
					// A frame is already in the non-preemptible WebSocket
					// write. Closing the connection is the only way to return
					// at the request deadline without letting that frame
					// outlive dispatch cleanup.
					if !req.state.CompareAndSwap(providerWriteInFlight, providerWriteCanceledInFlight) {
						continue
					}
					w.Close()
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
				case providerWriteCompleted:
					// The complete frame is already on the wire. Keep the
					// healthy connection and report the authoritative write
					// result. Request-context cancellation is handled by the
					// dispatch owner after it takes ownership of the sent frame.
					return metadata, nil
				case providerWriteRejected:
					// Rejection is terminal but does not mean bytes were written.
					return metadata, req.rejection
				case providerWriteAuthorizing:
					// Final authorization may be waiting for registry locks. It
					// has not exposed bytes; cancel without closing a healthy
					// socket and prevent the later 7→4 commit.
					if !req.state.CompareAndSwap(providerWriteAuthorizing, providerWriteCanceledBeforeHandoff) {
						continue
					}
					return metadata, ctx.Err()
				default:
					return metadata, ctx.Err()
				}
			}
		case <-w.done:
			takeReadyHandoff()
			return metadata, ResultAfterStop(ctx, req)
		}
	}
}

func ResultAfterStop(
	ctx context.Context,
	req *Request,
) error {
	// Writer shutdown may race the per-request completion publication. A
	// buffered request result is authoritative: in particular, a fully written
	// frame must not be reclassified as stopped and trigger cleanup/refunds.
	select {
	case err := <-req.done:
		return err
	default:
	}
	if state := req.state.Load(); state == providerWriteCompleted {
		return nil
	} else if state == providerWriteRejected {
		return req.rejection
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return ErrStopped
}
