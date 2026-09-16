package providerframe

// A validated provider terminal announces draining before its pending slot is
// released. Consumer-side classification remains read-only so a delayed error
// cannot overwrite a newer heartbeat that announces recovery.
func (s *Service) noteProviderDraining(providerID, model string) {
	if s.deps.Registry().MarkDraining(providerID) {
		s.deps.Metrics.Incr("routing.provider_draining", []string{"model:" + model})
	}
}
