package store

import "context"

type memoryFloorEpochLock struct {
	ready chan struct{}
	users int
}

// WithEpochSettlementLock serializes each epoch's spending read, allocation
// and atomic commit. The store-state mutex must remain free while fn runs.
func (s *MemoryStore) WithEpochSettlementLock(ctx context.Context, epoch string, fn func() error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.floorEpochMu.Lock()
	if s.floorEpochs == nil {
		s.floorEpochs = make(map[string]*memoryFloorEpochLock)
	}
	lock := s.floorEpochs[epoch]
	if lock == nil {
		lock = &memoryFloorEpochLock{ready: make(chan struct{}, 1)}
		lock.ready <- struct{}{}
		s.floorEpochs[epoch] = lock
	}
	lock.users++
	s.floorEpochMu.Unlock()
	defer func() {
		s.floorEpochMu.Lock()
		lock.users--
		if lock.users == 0 {
			delete(s.floorEpochs, epoch)
		}
		s.floorEpochMu.Unlock()
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
