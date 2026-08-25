package store

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
)

func (s *MemoryStore) GetActiveHardwareAdmissionPolicy(_ context.Context) (*hardwareadmission.Policy, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.activeHardwarePolicy == 0 {
		return nil, nil
	}
	policy, ok := s.hardwareAdmissionPolicies[s.activeHardwarePolicy]
	if !ok {
		return nil, fmt.Errorf("store: active hardware admission policy %d missing", s.activeHardwarePolicy)
	}
	cp := policy
	cp.GrandfatheredProviderCount = 0
	for _, admission := range s.hardwareAdmissions {
		if admission.Source == "grandfathered" && admission.RevokedAt == nil {
			cp.GrandfatheredProviderCount++
		}
	}
	return &cp, nil
}

func (s *MemoryStore) ActivateHardwareAdmissionPolicy(
	_ context.Context,
	policy hardwareadmission.Policy,
	expectedCurrentVersion int64,
	liveGrandfathered ...HardwareAdmission,
) (hardwareadmission.Policy, error) {
	if policy.CatalogVersion == "" {
		policy.CatalogVersion = hardwareadmission.CatalogVersion
	}
	if err := policy.ValidateForActivation(); err != nil {
		return hardwareadmission.Policy{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.activeHardwarePolicy != expectedCurrentVersion {
		return hardwareadmission.Policy{}, fmt.Errorf(
			"%w: expected %d, active %d",
			ErrHardwareAdmissionPolicyConflict, expectedCurrentVersion, s.activeHardwarePolicy)
	}

	var maxVersion int64
	hadEnforcement := false
	for version, prior := range s.hardwareAdmissionPolicies {
		if version > maxVersion {
			maxVersion = version
		}
		if prior.Mode == hardwareadmission.ModeEnforce {
			hadEnforcement = true
		}
	}
	policy.Version = maxVersion + 1
	policy.CreatedAt = time.Now().UTC()

	if policy.Mode == hardwareadmission.ModeEnforce && !hadEnforcement {
		cutoff := policy.CreatedAt
		policy.GrandfatherCutoffAt = &cutoff
		addGrandfathered := func(serial string, hardware hardwareadmission.Observed) {
			serial = normalizeHardwareSerial(serial)
			if serial == "" {
				return
			}
			if _, exists := s.hardwareAdmissions[serial]; exists {
				return
			}
			s.hardwareAdmissions[serial] = HardwareAdmission{
				SerialNumber:  serial,
				Source:        "grandfathered",
				PolicyVersion: policy.Version,
				Hardware:      hardware,
				AdmittedAt:    cutoff,
			}
			policy.GrandfatheredProviderCount++
		}
		for _, provider := range s.providerRecords {
			serial := normalizeHardwareSerial(provider.SerialNumber)
			if serial == "" || provider.TrustLevel != "hardware" {
				continue
			}
			var hardware hardwareadmission.Observed
			if len(provider.Hardware) > 0 {
				if err := json.Unmarshal(provider.Hardware, &hardware); err != nil {
					return hardwareadmission.Policy{},
						fmt.Errorf("store: decode grandfathered provider hardware: %w", err)
				}
			}
			addGrandfathered(serial, hardware)
		}
		for _, admission := range liveGrandfathered {
			addGrandfathered(admission.SerialNumber, admission.Hardware)
		}
	}

	s.hardwareAdmissionPolicies[policy.Version] = policy
	s.activeHardwarePolicy = policy.Version
	return policy, nil
}

func (s *MemoryStore) IsHardwareAdmitted(_ context.Context, serialNumber string) (bool, error) {
	serial := normalizeHardwareSerial(serialNumber)
	if serial == "" {
		return false, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	admission, ok := s.hardwareAdmissions[serial]
	return ok && admission.RevokedAt == nil, nil
}

func (s *MemoryStore) IsHardwareAdmissionRevoked(_ context.Context, serialNumber string) (bool, error) {
	serial := normalizeHardwareSerial(serialNumber)
	if serial == "" {
		return false, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	admission, ok := s.hardwareAdmissions[serial]
	return ok && admission.RevokedAt != nil, nil
}

func (s *MemoryStore) AdmitHardware(_ context.Context, admission HardwareAdmission) error {
	serial := normalizeHardwareSerial(admission.SerialNumber)
	if serial == "" {
		return fmt.Errorf("store: hardware admission serial is required")
	}
	if admission.Source == "" {
		admission.Source = "policy"
	}
	if admission.AdmittedAt.IsZero() {
		admission.AdmittedAt = time.Now().UTC()
	}
	admission.SerialNumber = serial

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.activeHardwarePolicy != admission.PolicyVersion {
		return fmt.Errorf(
			"%w: admission policy %d, active %d",
			ErrHardwareAdmissionPolicyConflict,
			admission.PolicyVersion,
			s.activeHardwarePolicy)
	}
	if existing, exists := s.hardwareAdmissions[serial]; exists {
		if existing.RevokedAt != nil {
			return fmt.Errorf("%w: %s", ErrHardwareAdmissionRevoked, serial)
		}
		return nil
	}
	s.hardwareAdmissions[serial] = admission
	return nil
}

func (s *MemoryStore) ListHardwareAdmissions(_ context.Context, limit int) ([]HardwareAdmission, error) {
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]HardwareAdmission, 0, min(limit, len(s.hardwareAdmissions)))
	for _, admission := range s.hardwareAdmissions {
		out = append(out, admission)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AdmittedAt.After(out[j].AdmittedAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (s *MemoryStore) RevokeHardwareAdmission(
	_ context.Context,
	serialNumber, actor, reason string,
) error {
	serial := normalizeHardwareSerial(serialNumber)
	if serial == "" || actor == "" || reason == "" {
		return fmt.Errorf("store: serial, actor, and reason are required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	admission, ok := s.hardwareAdmissions[serial]
	if !ok || admission.RevokedAt != nil {
		return fmt.Errorf("%w: hardware admission %s", ErrNotFound, serial)
	}
	now := time.Now().UTC()
	admission.RevokedAt = &now
	admission.RevokedBy = actor
	admission.RevocationReason = reason
	s.hardwareAdmissions[serial] = admission
	return nil
}

func (s *MemoryStore) RestoreHardwareAdmission(
	_ context.Context,
	serialNumber, actor, reason string,
) error {
	serial := normalizeHardwareSerial(serialNumber)
	if serial == "" || actor == "" || reason == "" {
		return fmt.Errorf("store: serial, actor, and reason are required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	admission, ok := s.hardwareAdmissions[serial]
	if !ok || admission.RevokedAt == nil {
		return fmt.Errorf("%w: hardware admission %s", ErrNotFound, serial)
	}
	admission.RevokedAt = nil
	admission.RevokedBy = ""
	admission.RevocationReason = ""
	s.hardwareAdmissions[serial] = admission
	return nil
}

func (s *MemoryStore) RecordHardwareAdmissionAttempt(_ context.Context, attempt HardwareAdmissionAttempt) error {
	if attempt.CreatedAt.IsZero() {
		attempt.CreatedAt = time.Now().UTC()
	}
	attempt.SerialNumber = normalizeHardwareSerial(attempt.SerialNumber)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.hardwareAdmissionAttemptSeq++
	attempt.ID = s.hardwareAdmissionAttemptSeq
	s.hardwareAdmissionAttempts = append(s.hardwareAdmissionAttempts, attempt)
	if excess := len(s.hardwareAdmissionAttempts) - DefaultPruneMaxEntries; excess > 0 {
		copy(s.hardwareAdmissionAttempts, s.hardwareAdmissionAttempts[excess:])
		s.hardwareAdmissionAttempts = s.hardwareAdmissionAttempts[:len(s.hardwareAdmissionAttempts)-excess]
	}
	return nil
}

func (s *MemoryStore) ListHardwareAdmissionAttempts(_ context.Context, accountID string, limit int) ([]HardwareAdmissionAttempt, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]HardwareAdmissionAttempt, 0, limit)
	for i := len(s.hardwareAdmissionAttempts) - 1; i >= 0 && len(out) < limit; i-- {
		attempt := s.hardwareAdmissionAttempts[i]
		if accountID != "" && attempt.AccountID != accountID {
			continue
		}
		out = append(out, attempt)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out, nil
}
