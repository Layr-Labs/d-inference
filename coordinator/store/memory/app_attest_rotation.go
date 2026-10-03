package memory

import (
	"context"
	"encoding/json"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// appAttestRotationFailureContext mirrors the archived evidence context
// fields used by the memory backend; PostgreSQL evaluates the same rule.
type appAttestRotationFailureContext struct {
	KeyID      string `json:"key_id"`
	Source     string `json:"apple_error_source"`
	AppleError *struct {
		Domain string `json:"domain"`
		Code   int64  `json:"code"`
	} `json:"apple_error"`
}

// A synthetic proof_oversize failure means Apple did return a proof, so the
// key is alive; it never counts toward rotation.
func appAttestRotationEligibleFailure(e store.AppAttestEvidence, outcome, keyID string) bool {
	if e.Action != "assertion" || outcome != "apple_error" || e.KeyID != keyID {
		return false
	}
	var c appAttestRotationFailureContext
	if json.Unmarshal(e.Context, &c) != nil || c.KeyID != keyID || c.Source == "proof_oversize" {
		return false
	}
	return c.AppleError == nil || c.AppleError.Domain == "devicecheck" && (c.AppleError.Code == 0 || c.AppleError.Code == 2)
}

func (s *MemoryStore) RecordAppAttestKeyRotation(ctx context.Context, r store.AppAttestKeyRotation) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestRotations == nil {
		s.appAttestRotations = map[string]store.AppAttestKeyRotation{}
	}
	if _, ok := s.appAttestRotations[r.KeyID]; ok {
		return false, nil
	}
	s.appAttestRotations[r.KeyID] = r
	return true, nil
}

func (s *MemoryStore) AdmitAppAttestKeyRotation(ctx context.Context, r store.AppAttestKeyRotation, limits []store.AppAttestRotationLimit) (*store.AppAttestKeyRotation, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestRotations == nil {
		s.appAttestRotations = map[string]store.AppAttestKeyRotation{}
	}
	if existing, ok := s.appAttestRotations[r.KeyID]; ok {
		return &existing, false, nil
	}
	canonical, err := s.canonicalMachineIDLocked(r.MachineID)
	if err != nil {
		return nil, false, err
	}
	if canonical != "" {
		r.MachineID = canonical
	}
	family := s.rotationScopeFamily(r.MachineID)
	for _, limit := range limits {
		since, n := r.RequestedAt.Add(-limit.Window), 0
		for _, other := range s.appAttestRotations {
			if family[other.MachineID] && !other.RequestedAt.Before(since) {
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
	canonical, err := s.canonicalMachineIDLocked(machineID)
	if err != nil {
		return 0, err
	}
	if canonical != "" {
		machineID = canonical
	}
	family := s.rotationScopeFamily(machineID)
	n := 0
	for _, r := range s.appAttestRotations {
		if family[r.MachineID] && !r.RequestedAt.Before(since) {
			n++
		}
	}
	return n, nil
}

// rotationScopeFamily mirrors appAttestRotationWindowCount: the scope plus
// every machine merged into it. Callers hold s.mu.
func (s *MemoryStore) rotationScopeFamily(scope string) map[string]bool {
	family := map[string]bool{scope: true}
	if s.machineInventory == nil {
		return family
	}
	for grew := true; grew; {
		grew = false
		for old, next := range s.machineInventory.merged {
			if family[next] && !family[old] {
				family[old], grew = true, true
			}
		}
	}
	return family
}

func (s *MemoryStore) GetAppAttestKeyRotation(ctx context.Context, keyID string) (*store.AppAttestKeyRotation, error) {
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
	return min(n, store.AppAttestRotationCountCap), nil
}

func (s *MemoryStore) AppAttestEnrollmentInvalidKeyFailureTimes(ctx context.Context, machineID, accountID string, since time.Time) ([]time.Time, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if machineID == "" && accountID == "" {
		return nil, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	m := s.machineInventory
	if m == nil {
		return nil, nil
	}
	var times []time.Time
	for _, e := range s.appAttestEvidence {
		if e.Evidence.Action != "attestation" || e.Decision.Outcome != "apple_invalid_key" || e.Evidence.ReceivedAt.Before(since) {
			continue
		}
		session := e.Evidence.SessionID
		if _, known := m.sessions[session]; !known {
			continue
		}
		if machineID != "" && m.sessionMachines[session] == machineID || machineID == "" && m.sessions[session].AccountID == accountID {
			times = append(times, e.Evidence.ReceivedAt)
		}
	}
	slices.SortFunc(times, func(a, b time.Time) int { return b.Compare(a) })
	return times[:min(len(times), store.AppAttestRotationCountCap)], nil
}
