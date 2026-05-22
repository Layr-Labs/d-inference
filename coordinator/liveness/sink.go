package liveness

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Sink adapts the Writer + SessionTracker pair into a single value the
// registry can hold via its registry.LivenessSink interface. It exists so
// the registry package can stay free of an explicit import of this package
// (we'd otherwise get a cycle through tests that wire everything together).
type Sink struct {
	Writer   *Writer
	Sessions *SessionTracker
}

// NewSink returns a sink wrapping the provided writer + tracker. Either
// component may be nil — calls to the nil component become no-ops, so a
// partial wire-up (e.g. heartbeats only, no session tracking) still works.
func NewSink(w *Writer, s *SessionTracker) *Sink {
	return &Sink{Writer: w, Sessions: s}
}

func (s *Sink) EmitHeartbeat(ev store.HeartbeatEvent) {
	if s == nil || s.Writer == nil {
		return
	}
	s.Writer.Emit(ev)
}

func (s *Sink) OpenSession(providerID string) {
	if s == nil || s.Sessions == nil {
		return
	}
	s.Sessions.Open(providerID)
}

func (s *Sink) CloseSession(providerID, reason string, lastHeartbeat time.Time, requestsServed, tokensGenerated int64) {
	if s == nil || s.Sessions == nil {
		return
	}
	s.Sessions.Close(providerID, reason, lastHeartbeat, requestsServed, tokensGenerated)
}
