package providerwrite

import (
	"context"
	"time"
)

// Execute advances one dequeued request through preparation, authorization and
// transport completion. The single lane consumer owns execution; publication
// is separate so terminal ownership is authoritative before notification.
func (w *Writer) Execute(req *Request) bool {
	startedState := providerWriteInFlight
	if req.beforeWrite != nil {
		startedState = providerWriteAuthorizing
	}
	if req.builder != nil {
		startedState = providerWriteBuilding
	}
	if req.CanceledBeforeHandoff() || (req.ctx != nil && req.ctx.Err() != nil) ||
		!req.state.CompareAndSwap(providerWriteQueued, startedState) {
		if req.done != nil {
			if req.ctx != nil && req.ctx.Err() != nil {
				req.result = req.ctx.Err()
			} else {
				req.result = context.Canceled
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
			req.handoff <- Metadata{}
			if req.done != nil {
				req.result = err
			}
			return true
		}
		// Atomically transfer the immutable frame from building to socket
		// handoff. Context cancellation can claim state 2 first, in which case
		// the builder is allowed to finish but its frame is discarded.
		if (req.ctx != nil && req.ctx.Err() != nil) ||
			!req.state.CompareAndSwap(providerWriteBuilding, providerWriteAwaitingOwner) {
			req.handoff <- Metadata{}
			if req.done != nil {
				if req.ctx != nil && req.ctx.Err() != nil {
					req.result = req.ctx.Err()
				} else {
					req.result = context.Canceled
				}
			}
			return true
		}
		req.handoff <- Metadata{DequeuedAt: dequeuedAt}
		select {
		case <-req.handoffAck:
		case <-req.ctx.Done():
			req.state.CompareAndSwap(providerWriteAwaitingOwner, providerWriteCanceledBeforeHandoff)
			if req.done != nil {
				req.result = req.ctx.Err()
			}
			return true
		case <-w.stop:
			if req.done != nil {
				req.result = ErrStopped
			}
			return false
		}
		if !req.state.CompareAndSwap(providerWriteAwaitingOwner, providerWriteAuthorizing) {
			if req.done != nil {
				if req.ctx != nil && req.ctx.Err() != nil {
					req.result = req.ctx.Err()
				} else {
					req.result = context.Canceled
				}
			}
			return true
		}
	}
	if req.beforeWrite != nil {
		if err := req.beforeWrite(); err != nil {
			req.rejection = err
			req.state.CompareAndSwap(providerWriteAuthorizing, providerWriteRejected)
			if req.done != nil {
				req.result = err
			}
			return true
		}
	}
	if req.builder != nil || req.beforeWrite != nil {
		if w.Closed() {
			req.state.CompareAndSwap(providerWriteAuthorizing, providerWriteCanceledBeforeHandoff)
			if req.done != nil {
				req.result = ErrStopped
			}
			w.drainAll(ErrStopped)
			return false
		}
		if (req.ctx != nil && req.ctx.Err() != nil) || !req.state.CompareAndSwap(providerWriteAuthorizing, providerWriteInFlight) {
			req.state.CompareAndSwap(providerWriteAuthorizing, providerWriteCanceledBeforeHandoff)
			if req.done != nil {
				if req.ctx != nil && req.ctx.Err() != nil {
					req.result = req.ctx.Err()
				} else {
					req.result = context.Canceled
				}
			}
			return true
		}
	}
	var writeErr error
	if w.transport == nil {
		writeErr = ErrStopped
	} else {
		writeErr = w.transport.Write(data)
	}
	if err := writeErr; err != nil {
		if req.done != nil {
			req.result = err
		}
		w.Close()
		w.drainAll(err)
		return false
	}
	if !req.state.CompareAndSwap(providerWriteInFlight, providerWriteCompleted) {
		// Cancellation won the write-completion race. Ensure the connection is
		// unusable before dispatch cleanup can release the request reservation.
		w.Close()
		if req.done != nil {
			if req.ctx != nil && req.ctx.Err() != nil {
				req.result = req.ctx.Err()
			} else {
				req.result = context.Canceled
			}
		}
		return false
	}
	if req.done != nil {
		req.result = nil
	}
	return true
}

// serve publishes the execution result before accepting the next frame.
func (w *Writer) serve(req *Request) bool {
	keep := w.Execute(req)
	req.Publish()
	return keep
}
