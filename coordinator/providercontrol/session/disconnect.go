package session

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
	"nhooyr.io/websocket"
)

// sessionDisconnectReason maps a provider read-loop exit to the disconnect
// reason recorded on its provider_sessions row. Kept to a small, fixed
// vocabulary so the column stays aggregatable:
//   - "oom_suspected"   — abrupt drop under memory pressure with in-flight work
//     (same classification as the provider.oom_suspected metric);
//   - "ws_close_<code>" — the peer sent a WebSocket close frame (1000 = normal
//     shutdown, 1001 = going away, 1006/close codes from intermediaries, ...);
//   - "read_error"      — the socket died without a close frame (TCP reset,
//     NAT/LB teardown, machine went to sleep mid-write);
//   - "read_error_control_frame" — nhooyr failed while handling a peer
//     control frame (see readErrorDisconnectReason).
//
// readReason is the frame-less classification from readErrorDisconnectReason
// and is used only when neither stronger signal applies.
//
// The registry's own generic "disconnect" remains the reason for closes the
// read loop did NOT observe first — in practice the stale-eviction sweep —
// so post-fix, lingering "disconnect" rows ≈ silent drops reaped by eviction.
func sessionDisconnectReason(closeStatus websocket.StatusCode, oomSuspected bool, readReason string) string {
	switch {
	case oomSuspected:
		return string(registry.DisconnectReasonOOMSuspected)
	case closeStatus != -1:
		return "ws_close_" + strconv.Itoa(int(closeStatus))
	default:
		return readReason
	}
}

const (
	readErrorReasonGeneric      = "read_error"
	readErrorReasonControlFrame = "read_error_control_frame"
)

// readErrorDisconnectReason classifies a frame-less provider Read failure
// into a fixed two-value vocabulary shared by the ws_disconnects metric, the
// telemetry event, and the provider_sessions disconnect_reason column.
//
// nhooyr answers peer pings on its READ goroutine, with a 5s budget to take
// the connection's per-frame write lock and put the pong on the wire. When
// that fails, the library fails the Read with "failed to handle control frame
// opPing: failed to write control frame opPong: failed to acquire lock: ..."
// — the peer was alive (it just pinged us), so this is a
// coordinator-side write stall, not a network drop, and must not be counted
// with real drops. The same prefix covers any other control-frame handling
// failure (e.g. a malformed control frame); close frames are never wrapped
// this way (they surface as a CloseError on the peer_close branch).
func readErrorDisconnectReason(err error) string {
	if err != nil && strings.Contains(err.Error(), "failed to handle control frame") {
		return readErrorReasonControlFrame
	}
	return readErrorReasonGeneric
}

// closeSessionWithReason closes this connection's provider_sessions row with a
// specific disconnect reason. Synchronous with a short timeout: it must land
// before the deferred registry.Disconnect issues its generic "disconnect"
// close (first close wins in the store), and a bounded wait means a stalled DB
// delays only this connection's teardown by at most the timeout — the store's
// upsert semantics make the registry's later write a safe fallback if this one
// times out. The caller marks the provider StatusOffline before calling, so
// the wait is never routing-critical: the dead provider cannot be selected
// while the write is in flight.
func (s *Session) closeSessionWithReason(providerID, reason string) {
	if s.deps.Store() == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := s.deps.Store().CloseProviderSession(ctx, providerID, reason, time.Now()); err != nil {
		s.deps.Logger().Warn("failed to close provider session with reason",
			"provider_id", providerID, "reason", reason, "error", err)
	}
}

func (s *Session) readFailed(err error) {
	closeStatus := websocket.CloseStatus(err)
	oomSuspected := false
	readReason := readErrorReasonGeneric
	if closeStatus != -1 {
		s.peerCloseStatus = closeStatus
		s.deps.Logger().Info("provider websocket closed",
			"provider_id", s.providerID, "close_code", int(closeStatus))
		// Peer-initiated closes were previously unmetered — only
		// read_error incremented ws_disconnects_total — so dashboards
		// could not split graceful closes (update/shutdown) from drops.
		if s.deps.Telemetry.Metrics() != nil {
			s.deps.Telemetry.Metrics().IncCounter("ws_disconnects_total",
				metrics.Label{Name: "reason", Value: "peer_close"},
			)
		}
		s.deps.Telemetry.Incr("ws.disconnects", []string{
			"reason:peer_close",
			"code:" + strconv.Itoa(int(closeStatus)),
		})
	} else {
		readReason = readErrorDisconnectReason(err)
		s.deps.Logger().Error("provider websocket read error",
			"provider_id", s.providerID, "error", err, "reason", readReason)
		s.deps.Telemetry.Emit(context.Background(), protocol.SeverityWarn, protocol.KindConnectivity,
			"provider websocket read error",
			map[string]any{
				"provider_id": s.providerID,
				"ws_state":    "read_error",
				"reason":      readReason,
				"last_error":  err.Error(),
			})
		if s.deps.Telemetry.Metrics() != nil {
			s.deps.Telemetry.Metrics().IncCounter("ws_disconnects_total",
				metrics.Label{Name: "reason", Value: readReason},
			)
		}
		s.deps.Telemetry.Incr("ws.disconnects", []string{"reason:" + readReason})

		// An abrupt read_error under high last-known memory pressure with
		// active inference is very likely a jetsam OOM (the kill leaves no
		// other trace). Require in-flight > 0: a graceful shutdown/update
		// drains first (and may surface here as a frame-less EOF rather
		// than a clean close), so gating on in-flight avoids misreading a
		// drained going-away close as OOM. Idle-box kills are recovered by
		// the provider's crash-log scrape instead.
		if s.provider != nil {
			memPressure, inFlight := s.provider.DisconnectDiagnostics()
			if inFlight > 0 && registry.ClassifyDisconnectReason(true, memPressure, inFlight) == registry.DisconnectReasonOOMSuspected {
				oomSuspected = true
				if s.deps.Telemetry.Metrics() != nil {
					s.deps.Telemetry.Metrics().IncCounter("provider_oom_suspected_total")
				}
				s.deps.Telemetry.Incr("provider.oom_suspected", nil)
				s.deps.Telemetry.Emit(context.Background(), protocol.SeverityError, protocol.KindOOM,
					"provider disconnected under memory pressure (suspected OOM)",
					map[string]any{
						"provider_id":     s.providerID,
						"memory_pressure": memPressure,
						"in_flight":       inFlight,
					})
			}
		}
	}

	// Stamp this connection's session row with the observed socket
	// outcome. Every registry.Disconnect path writes the catch-all
	// "disconnect", which made 97% of provider_sessions rows carry a
	// single indistinguishable reason (2026-07-03 churn analysis). The
	// stamp is written synchronously BEFORE the deferred
	// registry.Disconnect so the store's first-close-wins semantics keep
	// the specific reason; the registry's later generic close becomes a
	// no-op. Skipped when:
	//   - provider == nil: never registered, so no session row exists
	//     (writing would fabricate a zero-duration row);
	//   - ctx.Err() != nil: coordinator shutdown — the next instance's
	//     startup reconcile labels these "coordinator_restart";
	//   - the registry no longer has the provider: registry.Disconnect
	//     already ran (stale eviction, duplicate-serial kick) and owns
	//     the reason for that path.
	if s.provider != nil && s.ctx.Err() == nil && s.deps.Registry().GetProvider(s.providerID) != nil {
		// The socket is dead, but the deferred registry.Disconnect
		// only runs after the stamp lands (first close wins requires
		// that order). Flip the provider offline first — StatusOffline
		// fails every routing-eligibility gate — so a slow store write
		// can never leave a dead provider selectable. Untrusted stays
		// untrusted: it is equally unroutable, and overwriting it would
		// make Disconnect's status-gated online/model decrements run a
		// second time after markUntrusted already decremented.
		s.provider.Mu().Lock()
		if s.provider.Status != registry.StatusUntrusted {
			s.provider.Status = registry.StatusOffline
		}
		s.provider.Mu().Unlock()
		s.closeSessionWithReason(s.providerID, sessionDisconnectReason(closeStatus, oomSuspected, readReason))
	}
	return
}

func (s *Session) disconnect() {
	if s.deps.Scheduler() != nil {
		s.deps.Scheduler().Unbind(s.schedulerSEKey, s.schedulerGeneration)
	}
	s.deps.CodeIdentity().ClearResumeChallenges(s.providerID)
	// End connection-continuity coverage with the EXACT coordinator-
	// observed disconnect time (before registry.Disconnect tears the
	// provider down), so the measured reconnect gap starts here rather
	// than at the last periodic coverage pass.
	s.deps.TrustReuse().StopProviderCoverage(s.providerID)
	s.deps.CodeIdentity().StopCoverageForProvider(s.providerID)
	s.deps.Registry().DisconnectWithReason(s.providerID, registry.ClassifyPeerClose(s.peerCloseStatus, false))
	s.conn.Close(websocket.StatusNormalClosure, "goodbye")
}
