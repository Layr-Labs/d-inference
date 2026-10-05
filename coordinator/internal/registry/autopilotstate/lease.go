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
	return l.grantMatches(state, session) && now.Before(l.until)
}

// activeNow is Active for checks that run per provider on every request. It
// reads the clock only for a matching grant, so a provider without one costs
// no clock read.
func (l *Lease) activeNow(state *protocol.ModelAutopilotState, session string, now func() time.Time) bool {
	return l.grantMatches(state, session) && now().Before(l.until)
}

// grantMatches reports every lease condition except expiry.
func (l *Lease) grantMatches(state *protocol.ModelAutopilotState, session string) bool {
	return l != nil && Consented(state) && !state.Paused && state.Active &&
		!state.ObserveOnly && !l.observeOnly && state.SessionID == session &&
		state.Revision == l.revision
}

func (l *Lease) Accept(state *protocol.ModelAutopilotState, control protocol.ModelAutopilotControl) {
	if Consented(state) && state.Revision == control.Revision {
		l.until = time.UnixMilli(control.ExpiresAtMS)
		l.revision = control.Revision
		l.observeOnly = control.ObserveOnly
	}
}
