package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

type memoryAppAttestEvidence struct {
	Evidence AppAttestEvidence
	Decision AppAttestDecision
}

func (s *MemoryStore) BeginAppAttestEvidence(ctx context.Context, e AppAttestEvidence) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestEvidence == nil {
		s.appAttestEvidence = map[string]memoryAppAttestEvidence{}
	}
	if _, ok := s.appAttestEvidence[e.ID]; ok {
		return errors.New("duplicate_evidence")
	}
	e.Proof = append([]byte(nil), e.Proof...)
	e.Context = append(json.RawMessage(nil), e.Context...)
	s.appAttestEvidence[e.ID] = memoryAppAttestEvidence{Evidence: e, Decision: AppAttestDecision{Outcome: "pending"}}
	return nil
}

func (s *MemoryStore) CompleteAppAttestEvidence(ctx context.Context, id string, d AppAttestDecision) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.appAttestEvidence[id]
	if !ok {
		return "", errors.New("evidence_missing")
	}
	if e.Decision.Outcome != "pending" {
		return e.Decision.Outcome, nil
	}
	if d.Outcome == "verified" && d.Key != nil {
		if s.appAttestShadowKeys == nil {
			s.appAttestShadowKeys = map[string]AppAttestShadowKey{}
		}
		old, ok := s.appAttestShadowKeys[d.Key.KeyID]
		if !ok {
			key := *cloneAppAttestKey(*d.Key)
			key.UpdatedAt = time.Now().UTC()
			s.appAttestShadowKeys[d.Key.KeyID] = key
		} else if old.Owner != d.Key.Owner || old.AppID != d.Key.AppID || old.Environment != d.Key.Environment || string(old.PublicKey) != string(d.Key.PublicKey) {
			d.Outcome = "key_owner_or_policy"
		}
	}
	if d.Outcome == "verified" && d.Counter != nil {
		old, ok := s.appAttestShadowKeys[d.KeyID]
		if !ok || old.Owner != d.Owner || old.Counter >= *d.Counter {
			d.Outcome = "counter_conflict"
		} else {
			old.Counter = *d.Counter
			old.UpdatedAt = time.Now().UTC()
			s.appAttestShadowKeys[d.KeyID] = old
		}
	}
	d.Details = append(json.RawMessage(nil), d.Details...)
	e.Decision = d
	s.appAttestEvidence[id] = e
	return d.Outcome, nil
}

func (s *MemoryStore) GetAppAttestAssertionDiagnostics(ctx context.Context, keyID string) (*AppAttestAssertionDiagnostics, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	var latest AppAttestEvidence
	found := false
	for _, row := range s.appAttestEvidence {
		e := row.Evidence
		if e.KeyID == keyID && e.Action == "assertion" && row.Decision.Outcome == "verified" &&
			(!found || e.ReceivedAt.After(latest.ReceivedAt) || e.ReceivedAt.Equal(latest.ReceivedAt) && e.ID > latest.ID) {
			latest, found = e, true
		}
	}
	if !found {
		return nil, nil
	}
	// Match the bounded PostgreSQL window without copying or sorting proof rows.
	newer := 0
	for _, row := range s.appAttestEvidence {
		e := row.Evidence
		if e.KeyID == keyID && (e.ReceivedAt.After(latest.ReceivedAt) || e.ReceivedAt.Equal(latest.ReceivedAt) && e.ID > latest.ID) {
			newer++
			if newer >= AppAttestDiagnosticLookback {
				return nil, nil
			}
		}
	}
	var result AppAttestAssertionDiagnostics
	if err := json.Unmarshal(latest.Context, &result); err != nil {
		return nil, err
	}
	return &result, nil
}
