package requestqueue

import "sync"

// Assignment keeps reservation cleanup with the producer until the waiter
// acknowledges the exact target. Cancellation rejects an offer at most once.
// The zero value is ready to use.
type Assignment[T comparable] struct {
	mu      sync.Mutex
	pending *offer[T]
}

type offer[T comparable] struct {
	target  T
	cleanup func()
}

func (a *Assignment[T]) Offer(done <-chan struct{}, target T, cleanup func()) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	select {
	case <-done:
		return false
	default:
	}
	if a.pending != nil {
		return false
	}
	a.pending = &offer[T]{target: target, cleanup: cleanup}
	return true
}

func (a *Assignment[T]) Accept(target T) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.pending == nil || a.pending.target != target {
		return false
	}
	a.pending = nil
	return true
}

func (a *Assignment[T]) Reject() {
	var cleanup func()
	a.mu.Lock()
	if a.pending != nil {
		cleanup = a.pending.cleanup
		a.pending = nil
	}
	a.mu.Unlock()
	if cleanup != nil {
		cleanup()
	}
}
