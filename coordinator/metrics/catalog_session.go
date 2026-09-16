package metrics

// SessionMetrics is the provider WebSocket session lifecycle: registration,
// disconnection, and the frames the coordinator could not deliver. A provider
// session is the unit of fleet capacity, so these are the series that explain a
// registry that emptied out.
type SessionMetrics struct {
	// Registrations counts accepted registrations by the trust level the
	// provider was admitted at.
	Registrations *Counter
	// RegistrationRejected counts registrations refused before admission, by
	// reason.
	RegistrationRejected *Counter
	// VersionBelowMinimum counts providers refused for running below the version
	// floor, at whichever of the three gates caught it. `version` is the
	// coarse-grained version tag, not an exact patch level — an exact version
	// here would mint a series per release.
	VersionBelowMinimum *Counter

	// Disconnects is one session ending. `reason` separates a peer-initiated
	// close (update, shutdown) from a read error, and `code` carries the
	// WebSocket close status for the peer-close case only — a read error has no
	// close code, and the tag is absent rather than empty for those.
	//
	// Its in-process mirror is tagged by reason alone, which is what that series
	// has always been; the close-code split exists only on the Datadog side.
	Disconnects *Counter
	// OOMSuspected is an abrupt disconnect under memory pressure with work in
	// flight — a jetsam kill leaves no other trace, so this is inference, not
	// observation.
	OOMSuspected *Counter
	// EnqueueFailed is an outbound control frame that could not be queued for a
	// provider, by message kind. The provider does not learn what it missed.
	EnqueueFailed *Counter
}

func newSessionMetrics(m *Metrics) *SessionMetrics {
	disconnects := m.mirroredCounter("ws.disconnects", "ws_disconnects_total",
		"Provider WebSocket sessions ending, by reason and (for a peer close) close code",
		"reason", "code")
	// The mirror predates the close-code split and is a stored Prometheus
	// series; widening its key set here would silently break it.
	disconnects.mirrorPrefix = 1

	return &SessionMetrics{
		Registrations: m.mirroredCounter("providers.registrations", "provider_registrations_total",
			"Accepted provider registrations by admitted trust level",
			"trust_level"),
		RegistrationRejected: m.counter("providers.registration_rejected",
			"Registrations refused before admission, by reason",
			"reason"),
		VersionBelowMinimum: m.counter("provider_version_below_minimum",
			"Providers below the version floor, by the gate that caught it and coarse version tag",
			"gate", "version"),

		Disconnects: disconnects,
		OOMSuspected: m.mirroredCounter("provider.oom_suspected", "provider_oom_suspected_total",
			"Abrupt disconnects under memory pressure with inference in flight (suspected jetsam kill)"),
		EnqueueFailed: m.counter("provider.enqueue_failed",
			"Outbound control frames that could not be queued for a provider, by message kind",
			"msg"),
	}
}
