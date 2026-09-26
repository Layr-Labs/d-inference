package store

import (
	"context"
	"time"
)

func (s *MemoryStore) RecordAppAttestKeyRotation(ctx context.Context, r AppAttestKeyRotation) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestRotations == nil {
		s.appAttestRotations = map[string]AppAttestKeyRotation{}
	}
	if _, ok := s.appAttestRotations[r.KeyID]; ok {
		return false, nil
	}
	s.appAttestRotations[r.KeyID] = r
	return true, nil
}

func (s *MemoryStore) AdmitAppAttestKeyRotation(ctx context.Context, r AppAttestKeyRotation, limits []AppAttestRotationLimit) (*AppAttestKeyRotation, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestRotations == nil {
		s.appAttestRotations = map[string]AppAttestKeyRotation{}
	}
	if existing, ok := s.appAttestRotations[r.KeyID]; ok {
		return &existing, false, nil
	}
	for _, limit := range limits {
		since, n := r.RequestedAt.Add(-limit.Window), 0
		for _, other := range s.appAttestRotations {
			if other.MachineID == r.MachineID && !other.RequestedAt.Before(since) {
				n++
			}
		}
		if n >= limit.Max {
			return nil, false, nil
		}
	}
	s.appAttestRotations[r.KeyID] = r
	return nil, true, nil
}

func (s *MemoryStore) CountAppAttestKeyRotations(ctx context.Context, machineID string, since time.Time) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := 0
	for _, r := range s.appAttestRotations {
		if r.MachineID == machineID && !r.RequestedAt.Before(since) {
			n++
		}
	}
	return n, nil
}

func (s *MemoryStore) GetAppAttestKeyRotation(ctx context.Context, keyID string) (*AppAttestKeyRotation, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.appAttestRotations[keyID]
	if !ok {
		return nil, nil
	}
	return &r, nil
}

func (s *MemoryStore) CountAppAttestRotationFailures(ctx context.Context, keyID string, since time.Time) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := 0
	for _, e := range s.appAttestEvidence {
		if !e.Evidence.ReceivedAt.Before(since) && appAttestRotationEligibleFailure(e.Evidence, e.Decision.Outcome, keyID) {
			n++
		}
	}
	return min(n, AppAttestRotationCountCap), nil
}

func (s *MemoryStore) CountAppAttestEnrollmentInvalidKeyFailures(ctx context.Context, machineID, accountID string, since time.Time) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if machineID == "" && accountID == "" {
		return 0, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	m := s.machineInventory
	if m == nil {
		return 0, nil
	}
	n := 0
	for _, e := range s.appAttestEvidence {
		if e.Evidence.Action != "attestation" || e.Decision.Outcome != "apple_invalid_key" || e.Evidence.ReceivedAt.Before(since) {
			continue
		}
		session := e.Evidence.SessionID
		if _, known := m.sessions[session]; !known {
			continue
		}
		if machineID != "" && m.sessionMachines[session] == machineID || machineID == "" && m.sessions[session].AccountID == accountID {
			n++
		}
	}
	return min(n, AppAttestRotationCountCap), nil
}
