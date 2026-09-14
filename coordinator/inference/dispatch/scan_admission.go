package dispatch

import (
	"runtime"
	"time"
)

// DefaultRoutingConcurrency is the built-in routing-scan semaphore capacity:
// one scan per CPU (a scan is pure CPU under the registry read lock), floored
// at 2 so a tiny container never serializes routing entirely. Exported so
// main.go can log the effective default alongside the env override.
func DefaultRoutingConcurrency() int {
	n := runtime.NumCPU()
	if n < 2 {
		n = 2
	}
	return n
}

// SetRoutingConcurrency replaces the routing-scan semaphore with one of the
// given capacity (EIGENINFERENCE_ROUTING_CONCURRENCY). Values < 2 clamp to 2.
// Call before serving starts — replacing the channel while scans are in
// flight would strand slots.
func (s *Controller) SetRoutingConcurrency(n int) {
	if n < 2 {
		n = 2
	}
	s.routingScanSem = make(chan struct{}, n)
}

// ScanSlotResult is the outcome of acquireRoutingScanSlot. Client
// disconnection is distinguished from acquisition timeout so callers route a
// vanished caller onto the existing client-gone terminal (cancelled outcome,
// refund, no response body) and NEVER onto the routing_saturated 429 /
// rejection-ledger path.
type ScanSlotResult int

const (
	ScanSlotAcquired ScanSlotResult = iota
	ScanSlotTimeout
	ScanSlotClientGone
)

// acquireRoutingScanSlot blocks until a provider-selection scan slot is free,
// the wait budget elapses, or done fires (client gone). On scanSlotTimeout the
// caller sheds the attempt as capacity-shaped (errRoutingScanSaturated)
// instead of piling another scan onto saturated CPUs; on scanSlotClientGone it
// takes its ordinary client-gone path. A nil semaphore (a &Server{} built
// directly in tests) admits immediately, preserving legacy behavior for bare
// fixtures; a nil done channel never fires.
func (s *Controller) AcquireRoutingScanSlot(wait time.Duration, done <-chan struct{}) ScanSlotResult {
	if s.routingScanSem == nil {
		return ScanSlotAcquired
	}
	select {
	case s.routingScanSem <- struct{}{}:
		return ScanSlotAcquired
	default:
	}
	clientGone := func() bool {
		select {
		case <-done:
			return true
		default:
			return false
		}
	}
	if wait <= 0 {
		if clientGone() {
			return ScanSlotClientGone
		}
		return ScanSlotTimeout
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case s.routingScanSem <- struct{}{}:
		return ScanSlotAcquired
	case <-timer.C:
		if clientGone() {
			return ScanSlotClientGone
		}
		return ScanSlotTimeout
	case <-done:
		return ScanSlotClientGone
	}
}

// releaseRoutingScanSlot returns a slot taken by acquireRoutingScanSlot.
func (s *Controller) ReleaseRoutingScanSlot() {
	if s.routingScanSem == nil {
		return
	}
	<-s.routingScanSem
}
