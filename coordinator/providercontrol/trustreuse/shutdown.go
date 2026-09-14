package trustreuse

// StopCoverage cancels the periodic worker. The API then calls
// FinalCoverageSweep and its application-evidence sweep at the existing
// shutdown boundary. Cancellation intentionally retains the prior non-joining
// worker semantics.
func (s *Manager) StopCoverage() {
	if s != nil && s.coverageCancel != nil {
		s.coverageCancel()
	}
}

// StopReplay runs after final coverage, before API worker teardown.
func (s *Manager) StopReplay() {
	if s != nil && s.replayCancel != nil {
		s.replayCancel()
	}
}

// ReleaseAuthority remains separate from worker cancellation: the coordinator
// retains its lifetime journal lock through MDM and routing-worker shutdown.
func (s *Manager) ReleaseAuthority() {
	if s == nil {
		return
	}
	s.authorityMu.Lock()
	if s.authority != nil {
		_ = s.authority.Close()
		s.authority = nil
	}
	s.authorityMu.Unlock()
}
