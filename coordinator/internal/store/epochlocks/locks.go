package epochlocks

import (
	"context"
	"sync"
)

type Owner struct {
	mu    sync.Mutex
	locks map[string]*memoryFloorEpochLock
}

func (s *Owner) Len() int { s.mu.Lock(); defer s.mu.Unlock(); return len(s.locks) }

type memoryFloorEpochLock struct {
	ready chan struct{}
	users int
}

// WithEpochSettlementLock serializes each epoch's spending read, allocation
// and atomic commit. The store-state mutex must remain free while fn runs.
func (s *Owner) WithEpochSettlementLock(ctx context.Context, epoch string, fn func() error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	if s.locks == nil {
		s.locks = make(map[string]*memoryFloorEpochLock)
	}
	lock := s.locks[epoch]
	if lock == nil {
		lock = &memoryFloorEpochLock{ready: make(chan struct{}, 1)}
		lock.ready <- struct{}{}
		s.locks[epoch] = lock
	}
	lock.users++
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		lock.users--
		if lock.users == 0 {
			delete(s.locks, epoch)
		}
		s.mu.Unlock()
	}()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-lock.ready:
	}
	defer func() { lock.ready <- struct{}{} }()
	if err := ctx.Err(); err != nil {
		return err
	}
	return fn()
}
