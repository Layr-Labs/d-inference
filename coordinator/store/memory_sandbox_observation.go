package store

import "context"

func (s *MemoryStore) ObserveSandboxStopped(ctx context.Context, observation SandboxStoppedObservation) (bool, error) {
	if observation.ObservedAt.IsZero() {
		return false, ErrSandboxInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return false, err
	}
	sandbox := s.sandboxes[observation.SandboxID]
	if !observation.matches(sandbox) || sandbox.State != SandboxStateReady {
		return false, nil
	}
	for _, operation := range s.sandboxOperations {
		if operation.SandboxID == sandbox.ID && !operation.Terminal() {
			return false, nil
		}
	}
	sandbox.State, sandbox.ErrorCode = SandboxStateStopped, ""
	if observation.ObservedAt.After(sandbox.UpdatedAt) {
		sandbox.UpdatedAt = observation.ObservedAt
	}
	return true, nil
}
