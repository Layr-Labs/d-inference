package warmplan

import "time"

// LoadLifecycle tracks proactive placement dwell and session-local write retry
// eligibility. Its provider owner serializes operations with capacity changes.
type LoadLifecycle interface {
	Place(time.Time)
	BackoffUntil(time.Time)
	CanLoad(time.Time) bool
	DwellActive(time.Time, time.Duration) bool
	Reset()
}

type LoadState struct {
	placedAt time.Time
	retryAt  time.Time
}

func (s *LoadState) Place(now time.Time) { s.placedAt = now }

func (s *LoadState) BackoffUntil(deadline time.Time) { s.retryAt = deadline }

func (s *LoadState) CanLoad(now time.Time) bool { return !now.Before(s.retryAt) }

func (s *LoadState) DwellActive(now time.Time, dwell time.Duration) bool {
	return dwell > 0 && !s.placedAt.IsZero() && now.Sub(s.placedAt) < dwell
}

func (s *LoadState) Reset() {
	if s != nil {
		s.placedAt = time.Time{}
		s.retryAt = time.Time{}
	}
}
