package api

// finishSecurityInfo gives live and late grants the same MDA follow-up. A
// reconnect can replace the binding while cached proof verification runs.
func (s *mdmVerificationScheduler) finishSecurityInfo(binding mdmLiveBinding, udid string) {
	if s.deps.reuseMDA(binding) {
		s.metricCounter("mda_verification_total", "outcome", "reused")
		s.forgetBinding(binding)
	} else {
		s.enqueueMDA(binding, udid)
	}
}

func (s *mdmVerificationScheduler) forgetBinding(binding mdmLiveBinding) {
	seKey := binding.attestation.PublicKey
	s.mu.Lock()
	defer s.mu.Unlock()
	if current := s.bindings[seKey]; current != nil && current.generation == binding.generation {
		delete(s.bindings, seKey)
	}
}
