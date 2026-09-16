package memory

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) SaveAppAttestEnrollment(ctx context.Context, e contracts.AppAttestEnrollment) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestEnrollments == nil {
		s.appAttestEnrollments = map[string]contracts.AppAttestEnrollment{}
	}
	if _, ok := s.appAttestEnrollments[e.ID]; ok {
		return errors.New("enrollment_conflict")
	}
	s.appAttestEnrollments[e.ID] = e
	return nil
}

func (s *Store) GetAppAttestEnrollment(ctx context.Context, id string) (*contracts.AppAttestEnrollment, error) {
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
