package preload

import "time"

// A 409 never began a Rust replacement. Retire only this operation's lease,
// with no failed-member/backoff/residence transition and no success publication.
// An invalidated/ABA lease can retire itself but cannot become current again.
func (p *PreloadActiveSet) RetireConflict(now time.Duration, lease PreloadSelectionLease) bool {
	if !p.acceptTick(now) || p.inflight == nil || lease.Operation != p.inflight.Operation || !lease.Key.Equal(p.inflight.Key) {
		return false
	}
	invalidated := p.inflightInvalidated
	p.inflight = nil
	p.inflightInvalidated = false
	if invalidated || !p.valid || !lease.Key.Equal(p.key) {
		return false
	}
	p.needsLoad = true
	return true
}
