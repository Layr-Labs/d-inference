package memory

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/attestrecord"
)

func (s *Store) GetAppAttestShadowKey(ctx context.Context, id string) (*contracts.AppAttestShadowKey, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	k, ok := s.appAttestShadowKeys[id]
	if !ok {
		return nil, nil
	}
	return attestrecord.CloneAppAttestKey(k), nil
}

func (s *Store) InsertAppAttestShadowKey(ctx context.Context, key contracts.AppAttestShadowKey) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestShadowKeys == nil {
		s.appAttestShadowKeys = make(map[string]contracts.AppAttestShadowKey)
	}
	if _, ok := s.appAttestShadowKeys[key.KeyID]; ok {
		return false, nil
	}
	s.appAttestShadowKeys[key.KeyID] = *attestrecord.CloneAppAttestKey(key)
	return true, nil
}

func (s *Store) AdvanceAppAttestShadowCounter(ctx context.Context, id, owner string, counter uint32) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k, ok := s.appAttestShadowKeys[id]
	if !ok || k.Owner != owner || counter <= k.Counter {
		return false, nil
	}
	k.Counter = counter
	s.appAttestShadowKeys[id] = k
	return true, nil
}
