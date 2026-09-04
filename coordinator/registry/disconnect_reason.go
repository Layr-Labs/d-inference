package registry

import (
	"nhooyr.io/websocket"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Disconnect-reason plumbing: graceful disconnects are not provider sickness.
//
// The provider read loop already classifies how a socket ended — a
// peer-initiated close frame (1000 normal / 1001 going-away: a structured
// stop, an APNs-token refresh reconnect, a forced reconnect) versus a
// frame-less drop (read error, OOM-suspected kill) — but the generic
// Disconnect never received it, so the 502 flush of every in-flight request
// struck the provider's STABLE identity regardless (2/60 s inference-error
// cooldown, node breaker, health ejection, sticky pre-content terminal), and
// a provider that came straight back was pre-quarantined.
//
// DisconnectWithReason keeps the flush itself (the requests still fail over)
// but stamps a graceful close with CoordinatorCauseProviderRestart and the
// coordinator-internal error_reason provider_restart, which every health
// funnel treats as neutral (api.isProviderHealthNeutralErrorReason). An
// abrupt drop keeps the legacy CoordinatorCauseProviderDisconnected flush
// that strikes the identity: that is the reconnecting-zombie discriminator
// and must stay. A zombie that emits 1001 before reconnecting escapes the
// strike — a deliberate narrowing; watch ws.disconnects{reason:peer_close}
// per stable identity rather than adding a limiter here.
//
// NOTE: providers at or above the release carrying
// CoordinatorClient.closeForRestart() (provider-swift CoordinatorClient.swift;
// the auto-update restart and `darkbloom update`/`stop` drain and send a
// bounded goingAway close before exiting) reach the coordinator as
// ws_close_1001 → peer_close → provider_restart, so an upgrade wave on that
// fleet is health-neutral here. Providers below that release still send NO
// close frame on restart and surface as read_error (abrupt, strikes) until
// they are updated — the first fleet update after this coordinator deploys
// is the one wave that still strikes.

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
// outcome and the reason to persist on the provider_sessions row. A
// DisconnectReasonPeerClose flushes pending requests with the health-neutral
// restart cause; every other reason takes the abrupt path. sessionReason is
// written exactly once, by the disconnect itself (the read loop no longer
// races a synchronous stamp against the registry's generic close); an empty
// sessionReason falls back to the generic "disconnect".
func (r *Registry) DisconnectWithReason(id string, reason DisconnectReason, sessionReason string) {
	if sessionReason == "" {
		sessionReason = string(DisconnectReasonNormal)
	}
	r.disconnectWithCause(id, disconnectFlushCause(reason), sessionReason)
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
