package attempt

import "time"

// RecordAbandon records the cancellation before the caller parks or removes
// pending work. Expiry observations remain outside the tracker's lock.
func (s Service) RecordAbandon(requestID, model, cause string, now time.Time) bool {
	created, expired := s.deps.Tracker.record(requestID, model, cause, now)
	s.emitExpiredCancelEntries(expired)
	return created
}

// ForgetCancel drops correlation when a provider terminal already claimed the
// attempt and the abandoning caller therefore sent no cancellation.
func (s Service) ForgetCancel(requestID string) { s.deps.Tracker.forget(requestID) }

// Cause is the coordinator's bounded reason for recording the cancellation.
func (e Cancellation) Cause() string { return e.cause }

// Deliveries counts cancel frames accepted by the provider writer before the
// terminal consumed this immutable record.
func (e Cancellation) Deliveries() int { return e.sent }
