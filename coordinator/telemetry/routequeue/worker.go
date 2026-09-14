package routequeue

import "time"

// worker drains the queue until the sink is closed. The worker IS the
// long-lived goroutine — it runs each group inline (inside panic-safe
// wrappers) and never spawns a goroutine per op. carry holds an op that
// conflicted with the previous group and therefore opens the next one.
func (t *Sink) worker() {
	defer t.workers.Done()
	var carry *operation
	for {
		var first operation
		if carry != nil {
			first = *carry
		} else {
			select {
			case first = <-t.ch:
			case <-t.done:
				t.drainOnClose(nil)
				return
			}
		}
		g, next := t.gather(first, t.liveNext())
		t.execute(g)
		carry = next
		select {
		case <-t.done:
			t.drainOnClose(carry)
			return
		default:
		}
	}
}

// liveNext returns the op source for a live group: it blocks for the next op
// until the group window elapses or the sink is closed.
func (t *Sink) liveNext() func() (operation, bool) {
	var timer *time.Timer
	return func() (operation, bool) {
		if timer == nil {
			timer = time.NewTimer(t.window)
		}
		select {
		case op := <-t.ch:
			return op, true
		case <-timer.C:
			return operation{}, false
		case <-t.done:
			timer.Stop()
			return operation{}, false
		}
	}
}

// bufferedNext returns the op source for a closing drain: whatever is already
// buffered, without waiting.
func (t *Sink) bufferedNext() func() (operation, bool) {
	return func() (operation, bool) {
		select {
		case op := <-t.ch:
			return op, true
		default:
			return operation{}, false
		}
	}
}

// gather builds a group starting with first, pulling from next until the
// group is full, next runs dry, or an op conflicts with the group — in which
// case that op is returned as the carry for the following group.
func (t *Sink) gather(first operation, next func() (operation, bool)) (*group, *operation) {
	g := newGroup(t.maxBatch)
	g.add(first)
	for len(g.ops) < t.maxBatch {
		op, ok := next()
		if !ok {
			return g, nil
		}
		if g.conflicts(op) {
			return g, &op
		}
		g.add(op)
	}
	return g, nil
}

// drainOnClose writes everything buffered at Close time, in groups, without
// waiting for more. It runs on the worker goroutine after done is closed, so
// Close itself never blocks on it; CloseAndWait bounds how long a caller
// waits for it. Because Close rejects new submits, the buffer only shrinks.
func (t *Sink) drainOnClose(carry *operation) {
	next := t.bufferedNext()
	for {
		var first operation
		if carry != nil {
			first = *carry
		} else {
			op, ok := next()
			if !ok {
				return
			}
			first = op
		}
		g, more := t.gather(first, next)
		t.execute(g)
		carry = more
	}
}
