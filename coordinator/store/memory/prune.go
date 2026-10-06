package memory

func (s *MemoryStore) Prune(maxEntries int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.history.Prune(maxEntries)
}
