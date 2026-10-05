package session

import (
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// shutdownCloseStatus maps the read error of a socket the coordinator closed
// for shutdown (CloseNow sends no close frame, so the peer status is -1) to
// going-away, so the teardown flushes pending requests with the
// restart-neutral cause and the disconnect metrics count a shutdown close
// rather than a drop that strikes the provider's health.
func ShutdownCloseStatus(closeStatus websocket.StatusCode, closing bool) websocket.StatusCode {
	if closeStatus == -1 && closing {
		return websocket.StatusGoingAway
	}
	return closeStatus
}

// sessionDisconnectReasonCoordinatorShutdown stamps a session whose socket
// the coordinator itself closed for shutdown, or whose registration was
// processed after that close began: distinct from ws_close_<code>, which
// means the peer sent that close frame.
const DisconnectReasonCoordinatorShutdown = "coordinator_shutdown"

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
// closing marks a socket the coordinator closed for shutdown, stamped
// coordinator_shutdown whatever status the read reported.
func DisconnectReason(closeStatus websocket.StatusCode, oomSuspected bool, readReason string, closing bool) string {
	switch {
	case oomSuspected:
		return string(registry.DisconnectReasonOOMSuspected)
	case closing:
		return DisconnectReasonCoordinatorShutdown

	case closeStatus != -1:
		return "ws_close_" + strconv.Itoa(int(closeStatus))
	default:
		return readReason
	}
}

const (
	ReadErrorReasonGeneric      = "read_error"
	ReadErrorReasonControlFrame = "read_error_control_frame"
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
func ReadErrorDisconnectReason(err error) string {
	if err != nil && strings.Contains(err.Error(), "failed to handle control frame") {
		return ReadErrorReasonControlFrame

	}
	return ReadErrorReasonGeneric

}
