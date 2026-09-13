package store

import "context"

func (s *MemoryStore) GetAppAttestShadowKey(ctx context.Context, id string) (*AppAttestShadowKey, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	k, ok := s.appAttestShadowKeys[id]
	if !ok {
		return nil, nil
	}
	return cloneAppAttestKey(k), nil
}

func (s *MemoryStore) InsertAppAttestShadowKey(ctx context.Context, key AppAttestShadowKey) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestShadowKeys == nil {
		s.appAttestShadowKeys = make(map[string]AppAttestShadowKey)
	}
	if _, ok := s.appAttestShadowKeys[key.KeyID]; ok {
		return false, nil
	}
	s.appAttestShadowKeys[key.KeyID] = *cloneAppAttestKey(key)
	return true, nil
}

func (s *MemoryStore) AdvanceAppAttestShadowCounter(ctx context.Context, id, owner string, counter uint32) (bool, error) {
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
