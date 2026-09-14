package providerwriter

import (
	"context"
	"time"
)

func (w *Writer) run() {
	defer w.dead.Store(true)
	defer close(w.done)
	watchdogStop := make(chan struct{})
	go w.watchWrites(watchdogStop)
	defer close(watchdogStop)
	for {
		// Strict priority: serve any waiting control frame before data.
		select {
		case <-w.stop:
			w.drainAll(errStopped)
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
			w.drainAll(errStopped)
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
func (w *Writer) serve(req *writeRequest) bool {
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
				req.done <- errStopped
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
		w.CloseNow()
		w.drainAll(err)
		return false
	}
	if !req.state.CompareAndSwap(4, 5) {
		// Cancellation won the write-completion race. Ensure the connection is
		// unusable before dispatch cleanup can release the request reservation.
		w.CloseNow()
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

func (w *Writer) drainAll(err error) {
	w.drainLane(w.control, err)
	w.drainLane(w.queue, err)
}

func (w *Writer) drainLane(lane chan *writeRequest, err error) {
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
