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
