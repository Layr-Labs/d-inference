package memory

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) SaveAppAttestEnrollment(ctx context.Context, e store.AppAttestEnrollment) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestEnrollments == nil {
		s.appAttestEnrollments = map[string]store.AppAttestEnrollment{}
	}
	if _, ok := s.appAttestEnrollments[e.ID]; ok {
		return errors.New("enrollment_conflict")
	}
	s.appAttestEnrollments[e.ID] = e
	return nil
}

func (s *MemoryStore) GetAppAttestEnrollment(ctx context.Context, id string) (*store.AppAttestEnrollment, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	e, ok := s.appAttestEnrollments[id]
	if !ok {
		return nil, nil
	}
	return &e, nil
}
