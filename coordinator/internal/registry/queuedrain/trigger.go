package queuedrain

// Bounded triggers name the event that ran a queue drain. Unknown callers never
// contribute unbounded labels to the routing record.
const (
	TriggerHeartbeat  = "heartbeat"
	TriggerIdle       = "idle"
	TriggerChallenge  = "challenge"
	TriggerLoad       = "load"
	TriggerDisconnect = "disconnect"
	TriggerKick       = "kick"
	TriggerUnknown    = "unknown"
)

// FoldTrigger returns reason if it is one of the bounded Trigger* values,
// else TriggerUnknown. Constant strings only; no allocation.
func FoldTrigger(reason string) string {
	switch reason {
	case TriggerHeartbeat, TriggerIdle, TriggerChallenge, TriggerLoad,
		TriggerDisconnect, TriggerKick:
		return reason
	default:
		return TriggerUnknown
	}
}
