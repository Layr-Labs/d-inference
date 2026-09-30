package promptcontract

import "time"

// A 409 never began a Rust replacement. Retire only this operation's lease,
// with no failed-member/backoff/residence transition and no success publication.
// An invalidated/ABA lease can retire itself but cannot become current again.
func (p *preloadActiveSet) retireConflict(now time.Duration, lease preloadSelectionLease) bool {
	if !p.acceptTick(now) || p.inflight == nil || lease.operation != p.inflight.operation || !lease.key.equal(p.inflight.key) {
		return false
	}
	invalidated := p.inflightInvalidated
	p.inflight = nil
	p.inflightInvalidated = false
	if invalidated || !p.valid || !lease.key.equal(p.key) {
		return false
	}
	p.needsLoad = true
	return true
}
