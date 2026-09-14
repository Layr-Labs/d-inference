package routequeue

// Depth reports buffered operations; the worker may hold one additional batch.
func (t *Sink) Depth() int { return len(t.ch) }

// DroppedTotal reports operations rejected or discarded by the queue.
func (t *Sink) DroppedTotal() int64 { return t.dropped.Load() }
