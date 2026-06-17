package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// going_away.go is the API-layer glue for DAR-327 Phase 3 (instant reconnect):
// the version gate that decides which providers can be told the coordinator is
// going away, and a thin wrapper that broadcasts it during graceful shutdown.
// The wire mechanics (snapshot-then-write over the provider WebSockets) live in
// registry.BroadcastGoingAway; the version floor const lives next to its sibling
// in server.go. This mirrors the desired_models split (const in server.go,
// gate helper out of server.go).

// providerSupportsGoingAway reports whether a provider can receive the
// going_away message: it must run the Swift backend and report a version at or
// above minProviderVersionForGoingAway. A provider that reports no version is
// treated as too old (fail-closed) so a strict decoder never disconnects on an
// unknown message type. Mirrors providerSupportsDesiredModels.
func (s *Server) providerSupportsGoingAway(backend, version string) bool {
	if !registry.BackendUsesSwiftRuntime(backend) {
		return false
	}
	if version == "" {
		return false
	}
	return !semverLess(version, minProviderVersionForGoingAway)
}

// BroadcastGoingAway tells every connected, eligible provider that the
// coordinator is going away for a planned restart, gated by
// providerSupportsGoingAway. Called at the START of graceful shutdown (before
// any WebSocket teardown) so providers drain in-flight work and reconnect with
// their backoff reset onto the freshly-deployed coordinator. Returns the number
// of providers the message was successfully written to.
func (s *Server) BroadcastGoingAway() int {
	return s.registry.BroadcastGoingAway(s.providerSupportsGoingAway)
}
