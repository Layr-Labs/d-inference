package api

// A validated provider terminal announces draining before its pending slot is
// released. Consumer-side classification remains read-only so a delayed error
// cannot overwrite a newer heartbeat that announces recovery.
func (s *Server) noteProviderDraining(providerID, model string) {
	if s.registry.MarkDraining(providerID) {
		s.ddIncr("routing.provider_draining", []string{"model:" + model})
	}
}
