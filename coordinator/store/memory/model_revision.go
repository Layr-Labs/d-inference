package memory

import "github.com/eigeninference/d-inference/coordinator/store"

func (s *MemoryStore) RetireModelVersion(modelID, version string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	v := s.modelVersions[modelVersionKey(modelID, version)]
	if v == nil {
		return store.ErrNotFound
	}
	if s.activeModelVersion[modelID] == v.ID {
		return store.ErrActiveModelVersion
	}
	v.Status = "retired"
	return nil
}
