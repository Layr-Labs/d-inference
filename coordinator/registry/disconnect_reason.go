package registry

import (
	"nhooyr.io/websocket"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Disconnect-reason plumbing (R1: restart/graceful disconnects are not provider
// sickness).
//
// The provider read loop already classifies how a socket ended — a
// peer-initiated close frame (1000 normal / 1001 going-away: stop, restart,
// update) versus a frame-less drop (read error, OOM-suspected kill) — but the
// generic Disconnect never received it, so the 502 flush of every in-flight
// request struck the provider's STABLE identity regardless. After a fleet
// restart wave (2026-08-31: 19,001 in-flight across 316 providers) the
// upgraded boxes came back quarantined for up to five minutes.
//
// DisconnectWithReason keeps the flush itself (the requests still fail over)
// but stamps a graceful close with CoordinatorCauseProviderRestart and the
// coordinator-internal error_reason provider_restart, which every health
// funnel already treats as neutral (api.isProviderHealthNeutralErrorReason).
// An abrupt drop keeps the legacy CoordinatorCauseProviderDisconnected flush
// that strikes the identity: that is the reconnecting-zombie discriminator
// and must stay.
//
// NOTE: the Swift provider's auto-update restart (ProcessLifecycle.
// restartAfterUpdate → launchctl kickstart -k → exit) sends NO close frame
// today, so it reaches the coordinator as read_error and is NOT covered by
// this path; the version-changed reconnect reset (version_reset.go) is what
// covers that wave. Graceful closes come from the run() cancellation shutdown
// (CoordinatorClient.shutdown → goingAway) and any future SIGTERM trap.

const (
	// DisconnectReasonPeerClose: the provider sent a graceful WebSocket close
	// frame (1000 normal / 1001 going-away) — a stop, restart, or update. The
	// pending flush is health-neutral.
	DisconnectReasonPeerClose DisconnectReason = "peer_close"
	// DisconnectReasonReadError: the socket died without a close frame (TCP
	// reset, NAT/LB teardown, process killed, sleep). Abrupt: the flush
	// strikes the identity exactly as before.
	DisconnectReasonReadError DisconnectReason = "read_error"
)

// ClassifyPeerClose maps the read loop's observed close status to the
// DisconnectReason that decides the flush cause. closeStatus is
// websocket.CloseStatus(err): -1 when no close frame was received. Only the
// two graceful peer codes are restart-neutral; every other code (policy
// violations, abnormal 1006, intermediary codes, …) and every frame-less drop
// stays abrupt. oomSuspected wins outright — it is only ever set on a
// frame-less drop, but the guard keeps the precedence explicit.
func ClassifyPeerClose(closeStatus websocket.StatusCode, oomSuspected bool) DisconnectReason {
	switch {
	case oomSuspected:
		return DisconnectReasonOOMSuspected
	case closeStatus == websocket.StatusNormalClosure, closeStatus == websocket.StatusGoingAway:
		return DisconnectReasonPeerClose
	case closeStatus == -1:
		return DisconnectReasonReadError
	default:
		return DisconnectReasonNormal
	}
}

// DisconnectWithReason is Disconnect with the read loop's classified socket
// outcome. A DisconnectReasonPeerClose flushes pending requests with the
// health-neutral restart cause; every other reason takes the abrupt path.
func (r *Registry) DisconnectWithReason(id string, reason DisconnectReason) {
	r.disconnectWithCause(id, disconnectFlushCause(reason))
}

// disconnectFlushCause maps a DisconnectReason to the CoordinatorCause stamped
// on the flushed pending-request terminals.
func disconnectFlushCause(reason DisconnectReason) protocol.CoordinatorInferenceErrorCause {
	if reason == DisconnectReasonPeerClose {
		return protocol.CoordinatorCauseProviderRestart
	}
	return protocol.CoordinatorCauseProviderDisconnected
}

// disconnectFlushErrorReason is the error_reason stamped on the flushed
// terminals: the coordinator-internal provider_restart marker for a graceful
// close (health-neutral through the existing reason funnel), empty for the
// abrupt flush so its legacy provider_error classification is unchanged.
func disconnectFlushErrorReason(cause protocol.CoordinatorInferenceErrorCause) string {
	if cause == protocol.CoordinatorCauseProviderRestart {
		return protocol.InferenceErrorReasonProviderRestart
	}
	return ""
}
