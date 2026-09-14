package outcomequeue

import "time"

// Close rejects new snapshots and waits up to two seconds for the worker to
// drain accepted records. Each write retains its independent one-second limit.
func (q *Sink) Close() {
	if q == nil {
		return
	}
	q.mu.Lock()
	if !q.closed {
		q.closed = true
		close(q.stop)
	}
	q.mu.Unlock()
	select {
	case <-q.done:
	case <-time.After(2 * time.Second):
		if q.hooks.Logger != nil {
			q.hooks.Logger.Warn("request outcomes drain incomplete", "dropped", q.dropped.Load(), "queued", len(q.ch))
		}
	}
}
