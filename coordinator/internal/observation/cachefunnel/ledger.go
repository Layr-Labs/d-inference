package cachefunnel

import "sync"

// Ledger owns the aggregate funnel. It keeps no per-request history: a
// closed record is folded into fixed counters and offered to the Sink.
type Ledger struct {
	sink Sink

	mu      sync.Mutex
	entered uint64
	closed  uint64
	reasons [reasonCount]Totals
}

// NewLedger binds the receiver of every closed record. A nil sink keeps the
// aggregates only.
func NewLedger(sink Sink) *Ledger { return &Ledger{sink: sink} }

// Enter admits one request to the population. The caller must Close it.
func (l *Ledger) Enter() *Request {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	l.entered++
	l.mu.Unlock()
	return &Request{ledger: l}
}

func (l *Ledger) close(record Record) {
	l.mu.Lock()
	l.closed++
	l.reasons[record.Reason].add(record)
	l.mu.Unlock()
	if l.sink != nil {
		l.sink.ObserveCacheFunnelRecord(record)
	}
}

// Snapshot returns detached aggregates with every reason present, in
// lifecycle order.
func (l *Ledger) Snapshot() Status {
	status := Status{Reasons: make([]ReasonTotals, reasonCount), Unobserved: unobservedStages()}
	if l == nil {
		for i := range status.Reasons {
			status.Reasons[i].Reason = Reason(i).String()
		}
		return status
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	status.Entered, status.Closed, status.InFlight = l.entered, l.closed, l.entered-l.closed
	for i, totals := range l.reasons {
		status.Reasons[i] = ReasonTotals{Reason: Reason(i).String(), Totals: totals}
		status.Total.merge(totals)
	}
	return status
}
