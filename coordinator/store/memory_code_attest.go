package store

import "context"

func (s *MemoryStore) ListCodeAttestations(_ context.Context) ([]CodeAttestation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]CodeAttestation, 0, len(s.codeAttestations))
	for _, rec := range s.codeAttestations {
		out = append(out, rec)
	}
	return out, nil
}

func (s *MemoryStore) UpsertCodeAttestation(_ context.Context, rec CodeAttestation) error {
	if rec.SEPubKey == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	s.codeAttestations[rec.SEPubKey] = rec
	return nil
}

func (s *MemoryStore) DeleteCodeAttestation(_ context.Context, seKey string) error {
	if seKey == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.codeAttestations, seKey)
	return nil
}
