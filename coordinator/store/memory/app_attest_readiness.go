package memory

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) GetAppAttestReadiness(ctx context.Context, key string) (contracts.AppAttestReadiness, error) {
	if err := ctx.Err(); err != nil {
		return contracts.AppAttestReadiness{}, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	r := contracts.AppAttestReadiness{Revoked: s.appAttestRevocations[key]}
	var latest time.Time
	for _, e := range s.appAttestEvidence {
		if receipt := e.Decision.Receipt; receipt != nil && receipt.KeyID == key && receipt.Outcome == "verified" && receipt.ReceivedAt.After(latest) {
			copy := *receipt
			copy.Details = append(json.RawMessage(nil), receipt.Details...)
			r.Receipt = &copy
			latest = receipt.ReceivedAt
		}
	}
	return r, nil
}

func (s *Store) RevokeAppAttestKey(ctx context.Context, key, account, reason string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if account == "" || reason == "" || len(reason) > 128 {
		return false, errors.New("invalid_revocation")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k, ok := s.appAttestShadowKeys[key]
	if !ok || k.AccountID != account || s.appAttestRevocations[key] {
		return false, nil
	}
	if s.appAttestRevocations == nil {
		s.appAttestRevocations = map[string]bool{}
	}
	s.appAttestRevocations[key] = true
	return true, nil
}
