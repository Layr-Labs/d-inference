package authority

// CloseAuthority runs after route telemetry is flushed, preserving shutdown order.
func (s *Service,

) CloseAuthority() {
	if s == nil {
		return
	}
	s.trustAuthorityMu.Lock()
	if s.authorityLock != nil {
		_ = s.authorityLock.Close()
		s.authorityLock = nil
	}
	s.trustAuthorityMu.Unlock()
}
