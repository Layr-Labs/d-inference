package profilequeue

// Depth counts buffered jobs; the worker may also hold a batch.
func (p *Sink) Depth() int {
	if p == nil {
		return 0
	}
	return len(p.ch)
}

func (p *Sink) DroppedTotal() int64 {
	if p == nil {
		return 0
	}
	return p.dropped.Load()
}

func (p *Sink) WrittenTotal() int64 {
	if p == nil {
		return 0
	}
	return p.written.Load()
}
