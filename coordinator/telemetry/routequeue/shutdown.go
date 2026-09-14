package routequeue

import "time"

// Close marks the sink closed and signals the worker; it is idempotent and
// never blocks on in-flight telemetry writes: a stuck store call (the exact
// failure this sink guards against) must not be able to stall coordinator
// shutdown. After Close returns no new op can be accepted; the worker
// finishes the group it holds, writes what was buffered, and exits.
func (t *Sink) Close() {
	if t == nil {
		return
	}
	t.closeOnce.Do(func() {
		t.stateMu.Lock()
		t.closed = true
		close(t.done)
		t.stateMu.Unlock()
	})
}

// CloseAndWait closes the sink and waits up to timeout for the worker to
// finish its final drain, reporting whether it did. Server.Close uses it so
// buffered route rows reach the store before the process closes the pool;
// tests use it to observe the flush. Because Close rejects further submits,
// the drain cannot be prolonged by refills.
func (t *Sink) CloseAndWait(timeout time.Duration) bool {
	if t == nil {
		return true
	}
	t.Close()
	stopped := make(chan struct{})
	go func() {
		t.workers.Wait()
		close(stopped)
	}()
	select {
	case <-stopped:
		return true
	case <-time.After(timeout):
		return false
	}
}

// isClosed reports whether Close has been called (the worker is draining).
func (t *Sink) isClosed() bool {
	select {
	case <-t.done:
		return true
	default:
		return false
	}
}
