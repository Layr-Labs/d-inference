package mdmscheduler

// finishSecurityInfo gives live and late grants the same MDA follow-up. A
// reconnect can replace the binding while cached proof verification runs.
func (s *Scheduler) finishSecurityInfo(binding Binding, udid string) {
	if s.deps.ReuseMDA(binding.Target()) {
		s.metricCounter("mda_verification_total", "outcome", "reused")
		s.forgetBinding(binding)
	} else {
		s.enqueueMDA(binding, udid)
	}
}

func (s *Scheduler) forgetBinding(binding Binding) {
	seKey := binding.attestation.PublicKey
	s.mu.Lock()
	defer s.mu.Unlock()
	if current := s.bindings[seKey]; current != nil && current.generation == binding.generation {
		delete(s.bindings, seKey)
	}
}
