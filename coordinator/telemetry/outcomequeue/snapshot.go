package outcomequeue

// Stats samples independent process counters and queue depth. Like the
// underlying atomics, it is observational, not a transactional store snapshot.
type Stats struct {
	Received int64
	Written  int64
	Dropped  int64
	Failed   int64
	Queued   int
}

func (q *Sink) MarkReceived()        { q.received.Add(1) }
func (q *Sink) ReceivedTotal() int64 { return q.received.Load() }

func (q *Sink) Stats() Stats {
	return Stats{Received: q.received.Load(), Written: q.written.Load(), Dropped: q.dropped.Load(), Failed: q.failed.Load(), Queued: len(q.ch)}
}
