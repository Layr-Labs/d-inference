package sandboxhost

// Done closes when this exact connection loses authority through disconnect or
// replacement. Transient relays use it to stop waiting for a retired host.
func (s *Session) Done() <-chan struct{} {
	return s.authorityContext.Done()
}
