package legacymdm

// ForgetAccount removes the account's serials from the frozen runtime cohort.
// Readers retain immutable snapshots; startup loading and concurrent erasures
// serialize so a later publication cannot resurrect a removed membership.
func (s *Policy) ForgetAccount(account string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	old := s.cohort.Load()
	if old == nil {
		return
	}
	next := &cohort{machines: make(map[identity]string, len(old.machines))}
	for key, serial := range old.machines {
		if key.account != account {
			next.machines[key] = serial
		}
	}
	s.cohort.Store(next)
}
