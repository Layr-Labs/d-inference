package api

import (
	"encoding/json"
	"errors"
	"io"
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

// ClearGoingAway un-latches the going-away state so this coordinator accepts
// new provider registrations again. Used by the blue-green ROLLBACK path: when
// a cutover is reverted, the rolled-back-to color must stop refusing providers
// (handleProviderWS) and re-accept them. Safe for concurrent use.
func (s *Server) ClearGoingAway() { s.goingAway.Store(false) }

// handleGoingAway handles POST /v1/admin/going-away — the planned-restart trigger
// for the zero-downtime blue-green cutover (DAR-327 Phase 3). It is admin-gated
// (admin key OR Privy admin) via isAdminAuthorized.
//
// It accepts an OPTIONAL JSON body {"cancel": bool}:
//   - cancel:true  → ROLLBACK: un-latch the going-away flag via ClearGoingAway so
//     this coordinator re-accepts provider registrations, returning 200 with
//     {"going_away": false, "cleared": true}. The Phase 2 deploy.sh rollback path
//     calls exactly this.
//   - empty body / cancel absent / cancel:false → broadcast going_away to every
//     connected eligible provider, latch the going-away flag (refusing new
//     registrations thereafter), and return 200 with {"sent": <int>,
//     "going_away": true}.
//
// The route is wrapped in requireAuth (see routes()) so auth.UserFromContext is
// populated for the Privy-admin path; isAdminAuthorized then accepts either the
// admin key (a pseudo-account from requireAuth) or a Privy admin token.
func (s *Server) handleGoingAway(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	// Parse an OPTIONAL {"cancel": bool} body, mirroring handleAdminDrain's body
	// handling: tolerate an empty body (io.EOF), cap the read with MaxBytesReader,
	// map an over-cap body to 413 and any other decode error to 400. An empty
	// body / absent / false "cancel" keeps the default broadcast behavior.
	r.Body = http.MaxBytesReader(w, r.Body, maxControlPlaneBodyBytes)
	var req struct {
		Cancel bool `json:"cancel"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeJSON(w, http.StatusRequestEntityTooLarge,
				errorResponse("invalid_request_error", "request body too large"))
			return
		}
		writeJSON(w, http.StatusBadRequest,
			errorResponse("invalid_request_error", "invalid JSON"))
		return
	}

	// ROLLBACK (blue-green): a cutover was reverted, so this color must stop
	// refusing providers and re-accept registrations. CROSS-PHASE CONTRACT: the
	// Phase 2 deploy.sh rollback calls exactly this — POST {"cancel":true}.
	if req.Cancel {
		s.ClearGoingAway()
		s.logger.Info("admin cleared going_away (rollback)")
		writeJSON(w, http.StatusOK, map[string]any{"going_away": false, "cleared": true})
		return
	}

	sent := s.BroadcastGoingAway()
	s.logger.Info("admin triggered going_away broadcast", "sent", sent)
	writeJSON(w, http.StatusOK, map[string]any{"sent": sent, "going_away": true})
}
