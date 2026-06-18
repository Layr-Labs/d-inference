package api

import (
	"net/http"

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
// providerSupportsGoingAway. Called both from the admin POST /v1/admin/going-away
// endpoint (the blue-green cutover trigger) and at the START of graceful
// shutdown (before any WebSocket teardown) so providers drain in-flight work and
// reconnect with their backoff reset onto the freshly-deployed coordinator.
// Returns the number of providers the message was successfully written to.
//
// It also latches the goingAway flag FIRST so that any provider reconnecting
// after receiving the broadcast (or one that missed it) is refused a NEW
// registration on this dying instance — see handleProviderWS. The flag is set
// before the broadcast write so there is no window where a provider could close,
// reconnect, and re-register here in between.
func (s *Server) BroadcastGoingAway() int {
	s.goingAway.Store(true)
	return s.registry.BroadcastGoingAway(s.providerSupportsGoingAway)
}

// handleGoingAway handles POST /v1/admin/going-away — the discrete planned-restart
// trigger for the zero-downtime blue-green cutover (DAR-327 Phase 3). It is
// admin-gated (admin key OR Privy admin) via isAdminAuthorized, takes no body,
// broadcasts going_away to every connected eligible provider, latches the
// going-away flag (refusing new registrations on this instance thereafter), and
// returns 200 with {"sent": <int>} — the number of providers the message reached.
//
// The route is wrapped in requireAuth (see routes()) so auth.UserFromContext is
// populated for the Privy-admin path; isAdminAuthorized then accepts either the
// admin key (a pseudo-account from requireAuth) or a Privy admin token.
func (s *Server) handleGoingAway(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	sent := s.BroadcastGoingAway()
	s.logger.Info("admin triggered going_away broadcast", "sent", sent)
	writeJSON(w, http.StatusOK, map[string]any{"sent": sent})
}
