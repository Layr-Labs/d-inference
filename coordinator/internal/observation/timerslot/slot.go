// Package timerslot owns the retained handle for a single cancellable fallback.
package timerslot

import "time"

// Slot is zero when no timer handle is retained. Its caller serializes Arm and
// Retire with the same lock protecting the work the callback will complete.
type Slot struct{ timer *time.Timer }

func (s *Slot) Arm(delay time.Duration, run func()) {
	if s.timer == nil {
		s.timer = time.AfterFunc(delay, run)
	}
}

// Retire stops outstanding work and releases the handle even if it has fired.
func (s *Slot) Retire() {
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
}
