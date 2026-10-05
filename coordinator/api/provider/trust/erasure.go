package trust

// ForgetErasedKeys clears the in-memory trust state of erased SE keys: the
// trust-reuse records and the MDM scheduler's jobs and bindings. The erasure
// scrub already deleted their rows; these copies live outside the database.
func (s *Owner) ForgetErasedKeys(seKeys []string) {
	if s == nil || len(seKeys) == 0 {
		return
	}
	s.ForgetTrustReuse(seKeys)
	if s.verificationBackend.Scheduler != nil {
		s.verificationBackend.Scheduler.Forget(seKeys)
	}
}
