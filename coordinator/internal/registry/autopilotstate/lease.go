package autopilotstate

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Lease owns the latest successfully enqueued control grant for this session.
// Its zero value grants no authority. The provider lock serializes its use.
type Lease struct {
	until       time.Time
	revision    string
	observeOnly bool
}

func (l *Lease) Active(state *protocol.ModelAutopilotState, session string, now time.Time) bool {
	return l != nil && Consented(state) && !state.Paused && state.Active &&
		!state.ObserveOnly && !l.observeOnly && state.SessionID == session &&
		state.Revision == l.revision && now.Before(l.until)
}

func (l *Lease) Accept(state *protocol.ModelAutopilotState, control protocol.ModelAutopilotControl) {
	if Consented(state) && state.Revision == control.Revision {
		l.until = time.UnixMilli(control.ExpiresAtMS)
		l.revision = control.Revision
		l.observeOnly = control.ObserveOnly
	}
}
