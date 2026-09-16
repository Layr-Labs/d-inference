package memory

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/attestrecord"
)

type memoryAppAttestEvidence struct {
	Evidence contracts.AppAttestEvidence
	Decision contracts.AppAttestDecision
}

func (s *Store) BeginAppAttestEvidence(ctx context.Context, e contracts.AppAttestEvidence) error {
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
	s.appAttestEvidence[e.ID] = memoryAppAttestEvidence{Evidence: e, Decision: contracts.AppAttestDecision{Outcome: "pending"}}
	return nil
}

func (s *Store) CompleteAppAttestEvidence(ctx context.Context, id string, d contracts.AppAttestDecision) (string, error) {
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
			s.appAttestShadowKeys = map[string]contracts.AppAttestShadowKey{}
		}
		old, ok := s.appAttestShadowKeys[d.Key.KeyID]
		if !ok {
			s.appAttestShadowKeys[d.Key.KeyID] = *attestrecord.CloneAppAttestKey(*d.Key)
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
			s.appAttestShadowKeys[d.KeyID] = old
		}
	}
	d.Details = append(json.RawMessage(nil), d.Details...)
	e.Decision = d
	s.appAttestEvidence[id] = e
	return d.Outcome, nil
}
