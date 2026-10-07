package provider

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

// Provider WebSocket management for the Darkbloom coordinator.
//
// This file handles the provider side of the coordinator: WebSocket connections,
// provider registration, attestation verification, challenge-response loops,
// and inference request/response relay.
//
// Provider lifecycle:
//   1. Provider connects via WebSocket to /ws/provider
//   2. Provider sends a Register message with hardware info, models, and attestation
//   3. Coordinator verifies attestation (Secure Enclave P-256 signature)
//   4. Coordinator starts periodic challenge-response loop to verify liveness
//   5. Coordinator routes inference requests to the provider via WebSocket
//   6. Provider streams response chunks back through the WebSocket
//   7. Coordinator relays chunks to the waiting consumer HTTP handler
//
// Attestation trust levels:
//   - none: No attestation provided (Open Mode, still accepted)
//   - self_signed: Attestation signed by provider's own Secure Enclave key
//   - hardware: MDA certificate chain verified against Apple Root CA (future)

// HandleProviderWS upgrades the connection to WebSocket and manages the
// provider's lifecycle: registration, heartbeats, and inference responses.
func (s *Owner) HandleProviderWS(w http.ResponseWriter, r *http.Request) {
	done, admitted := s.sessions.Admit()
	if !admitted {
		http.Error(w, "coordinator shutting down", http.StatusServiceUnavailable)
		return
	}
	defer done()
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Allow any origin for provider connections.
		InsecureSkipVerify: true,
	})
	if err != nil {
		s.logger.Error("websocket accept failed", "error", err)
		return
	}

	s.sessions.Track(conn, true)
	defer s.sessions.Track(conn, false)

	// Raise the read limit to 10 MB. The default 32 KB is too small for
	// large inference responses.
	conn.SetReadLimit(10 * 1024 * 1024)

	providerID := uuid.New().String()
	s.logger.Info("provider websocket connected", "provider_id", providerID)

	// Run the read loop; on return the provider is disconnected.
	s.providerReadLoop(r.Context(), conn, providerID, r)
}

// CloseProviderConnections stops the provider socket producers for shutdown:
// no new provider socket is admitted, every hijacked socket the server has
// tracked since accept is closed (registered or not; the provider reconnects
// to the next coordinator, and its holders park for that reconnect), and the
// running handlers are joined so no receipt or heartbeat can arrive behind
// the caller. Provider sockets are hijacked, so httpServer.Shutdown neither
// closes nor waits on them. Returns false when the handlers did not all
// finish before ctx expired.
func (s *Owner) CloseProviderConnections(ctx context.Context) bool {
	conns := s.sessions.Quiesce()
	// Every hijacked socket, whether or not its provider registered; the
	// read loops return and tear their providers down through the ordinary
	// disconnect path, which parks their holders. In parallel: CloseNow
	// waits for the socket's goroutines, and one mid-handshake close must
	// not hold the others; the join below is what ctx bounds.
	for _, c := range conns {
		go func(c *websocket.Conn) { _ = c.CloseNow() }(c)
	}
	if s.WaitProviderHandlers(ctx) {
		s.logger.Info("provider sockets closed for shutdown", "closed", len(conns))
		return true
	}
	s.logger.Warn("provider socket handlers still running at the shutdown deadline", "closed", len(conns))
	return false
}

// WaitProviderHandlers waits until every admitted provider socket handler
// has returned or ctx expires. It may be called again after
// CloseProviderConnections reported a timeout: a handler can spend seconds
// in its read-error close and its deferred teardown, and evidence it marks
// meanwhile is only safe once a flush runs after it has returned.
func (s *Owner) WaitProviderHandlers(ctx context.Context) bool {
	if !s.providerSocketsClosing() {
		// Before the close, a handler may still be admitted (an Add from
		// zero would race this Wait); the call is a programming error.
		s.logger.Error("WaitProviderHandlers called before CloseProviderConnections")
		return false
	}
	return s.sessions.Wait(ctx)
}

// providerSocketsClosing reports whether shutdown has begun closing provider
// sockets. A read loop checks it right after registering and leaves at once:
// its socket is being closed, and nothing it could read now may produce a
// receipt behind the final flush. WaitProviderHandlers refuses to run before
// it is set.
func (s *Owner) providerSocketsClosing() bool {
	return s.sessions.Closing()
}

// maxProviderVersionLength bounds the provider-reported binary version accepted
// at registration. The Swift provider sends the compile-time constant
// ProviderCore.version ("0.8.15"; release tags must equal it, dev builds are
// published with the same exact-version contract), and the longest shape the
// coordinator has ever handled is "0.8.15-rc.1+build" (17 bytes). 128 leaves
// an order of magnitude of margin while keeping provider-controlled bytes out
// of the registry's parse memos, metric tags and logs. Raising this must be
// paired with the registry's memo bound (maxMemoizedVersionLen), which stops
// caching above 64 bytes.
const maxProviderVersionLength = 128

// closeSessionWithReason closes this connection's provider_sessions row with a
// specific disconnect reason. Synchronous with a short timeout: it must land
// before the deferred registry.Disconnect issues its generic "disconnect"
// close (first close wins in the store), and a bounded wait means a stalled DB
// delays only this connection's teardown by at most the timeout — the store's
// upsert semantics make the registry's later write a safe fallback if this one
// times out. The caller marks the provider StatusOffline before calling, so
// the wait is never routing-critical: the dead provider cannot be selected
// while the write is in flight.
func (s *Owner) closeSessionWithReason(providerID, reason string) {
	if s.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := s.store.CloseProviderSession(ctx, providerID, reason, time.Now()); err != nil {
		s.logger.Warn("failed to close provider session with reason",
			"provider_id", providerID, "reason", reason, "error", err)
	}
}

// countCloseDisconnect counts a disconnect the read loop classified by a
// close status: the peer's close frame, or going-away for a socket the
// coordinator closed for shutdown (and for a registration processed after
// that close began). Peer-initiated closes were once unmetered — only
// read_error incremented ws_disconnects_total — so dashboards could not
// split graceful closes (update, shutdown) from drops.
func (s *Owner) countCloseDisconnect(closeStatus websocket.StatusCode) {
	if s.observation.Metrics() != nil {
		s.observation.Metrics().IncCounter("ws_disconnects_total",
			observation.MetricLabel{Name: "reason", Value: "peer_close"},
		)
	}
	s.observation.Incr("ws.disconnects", []string{
		"reason:peer_close",
		"code:" + strconv.Itoa(int(closeStatus)),
	})
}

// closeSessionOffline flips the provider offline and stamps its session row
// with reason, ahead of the deferred registry.Disconnect (first close wins
// requires that order). Offline first — StatusOffline fails every
// routing-eligibility gate — so a slow store write can never leave a dead
// provider selectable. Untrusted stays untrusted: it is equally unroutable,
// and overwriting it would make Disconnect's status-gated online/model
// decrements run a second time after markUntrusted already decremented.
func (s *Owner) closeSessionOffline(providerID string, provider *registry.Provider, reason string) {
	provider.Mu().Lock()
	if provider.Status != registry.StatusUntrusted {
		provider.Status = registry.StatusOffline
	}
	provider.Mu().Unlock()
	s.closeSessionWithReason(providerID, reason)
}

// providerReadLoop reads messages from the provider WebSocket and dispatches
// them. It runs until the connection closes or the context is cancelled.
