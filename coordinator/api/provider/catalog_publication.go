package provider

func (s *Owner) HandleRuntimeCapabilitiesPromoted(providerID string) {
	provider := s.registry.GetProvider(providerID)
	if provider == nil {
		return
	}
	provider.Mu().Lock()
	backend := provider.Backend
	provider.Mu().Unlock()
	if !s.catalog.ProviderSupportsDesiredModels(backend) {
		return
	}
	entries := s.registry.DesiredModelsForProvider(providerID)
	if err := s.registry.SendDesiredModels(providerID, entries); err != nil {
		s.logger.Warn("failed to refresh desired_models after capability promotion",
			"provider_id", providerID,
			"error", err,
		)
	}
}
