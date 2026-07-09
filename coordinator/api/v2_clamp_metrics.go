package api

// v2 silent-legacy-fallback tripwire telemetry (DogStatsD + the in-process
// /v1/admin/metrics registry). The registry's version-keyed heartbeat clamp
// (registry/v2_capacity_clamp.go) fires this hook whenever a provider at or
// above the EIGENINFERENCE_V2_VERSION_FLOOR heartbeats a chat-slot
// max_concurrency above the v2 ceiling — on a >=floor box that report means
// the silent-legacy-fallback bug (2026-07-06 gemma postmortem) has resurfaced,
// so the counter is a PERMANENT audit of the v0.7.5 fail-loud promise, not a
// transient rollout metric. Tags are low-cardinality (model + binary version);
// the provider id is in the registry's ERROR log, never a tag.
func (s *Server) emitV2ClampTripwire(providerID, version, model string, reported int) {
	if s == nil {
		return
	}
	s.ddIncr("provider.v2_concurrency_tripwire", []string{"model:" + model, "version:" + version})
	if s.metrics != nil {
		s.metrics.IncCounter("provider.v2_concurrency_tripwire",
			MetricLabel{Name: "model", Value: model},
			MetricLabel{Name: "version", Value: version},
		)
	}
	if s.logger != nil {
		s.logger.Error("v2 max_concurrency tripwire fired — silent legacy fallback suspected",
			"provider_id", providerID,
			"provider_version", version,
			"model", model,
			"reported_max_concurrency", reported,
		)
	}
}
