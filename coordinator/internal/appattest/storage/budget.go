// Package storage owns the independent, nonblocking proof and optional
// diagnostic admission budgets. Inventory and receipt workers are separate.
package storage

import "sync"

// Budget's zero value retains the four-proof and one-diagnostic limits.
type Budget struct {
	proofOnce      sync.Once
	proof          chan struct{}
	diagnosticOnce sync.Once
	diagnostic     chan struct{}
}

func (b *Budget) AcquireProof() (func(), bool) {
	b.proofOnce.Do(func() { b.proof = make(chan struct{}, 4) })
	return acquire(b.proof)
}

func (b *Budget) AcquireDiagnostic() (func(), bool) {
	b.diagnosticOnce.Do(func() { b.diagnostic = make(chan struct{}, 1) })
	return acquire(b.diagnostic)
}

func acquire(slots chan struct{}) (func(), bool) {
	select {
	case slots <- struct{}{}:
		return func() { <-slots }, true
	default:
		return nil, false
	}
}
