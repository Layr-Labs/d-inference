package recovery

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type EnrollmentDependencies struct {
	Store            func() store.AppAttestKeyRotationStore
	Account          string
	CanonicalMachine func(context.Context, string) string
	Acquire          func() (func(), bool)
	AcquireWithin    func(context.Context, time.Duration) (func(), bool)
	Count            func(string)
	Observe          func(string)
}

type Enrollment struct{ deps EnrollmentDependencies }

func NewEnrollment(deps EnrollmentDependencies) *Enrollment { return &Enrollment{deps: deps} }

// Due is checked only after the current invalid-key attestation is archived.
func (e *Enrollment) Due(failure, expected string) bool {
	if failure != "apple_invalid_key" || expected != "attestation" {
		return false
	}
	release, ok := e.deps.Acquire()
	if !ok {
		return false
	}
	defer release()
	times, ok := e.failures(time.Now().UTC().Add(-EnrollmentInvalidKeyWindow))
	if !ok || len(times) < EnrollmentInvalidKeyThreshold {
		return false
	}
	e.observe("failure", "enrollment_backoff")
	return true
}

// Remaining re-derives the prior machine's trailing-window backoff at session
// start, so reconnecting cannot enroll a fresh key before the wait is served.
func (e *Enrollment) Remaining(ctx context.Context, now time.Time) time.Duration {
	release, ok := e.deps.AcquireWithin(ctx, EnrollmentPermitWait)
	if !ok {
		return 0
	}
	defer release()
	times, ok := e.failures(now.Add(-EnrollmentInvalidKeyBackoff - EnrollmentInvalidKeyWindow))
	if !ok {
		return 0
	}
	left := EnrollmentBackoffLeft(times, now)
	if left > 0 {
		e.observe("session_start", "enrollment_backoff_resumed")
	}
	return left
}

func (e *Enrollment) failures(since time.Time) ([]time.Time, bool) {
	st := e.deps.Store()
	if st == nil {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	machine := ""
	if e.deps.CanonicalMachine != nil {
		machine = e.deps.CanonicalMachine(ctx, "")
	}
	times, err := st.AppAttestEnrollmentInvalidKeyFailureTimes(ctx, machine, e.deps.Account, since)
	return times, err == nil
}

func (e *Enrollment) observe(phase, outcome string) {
	if e.deps.Count != nil {
		e.deps.Count(phase)
	}
	if e.deps.Observe != nil {
		e.deps.Observe(outcome)
	}
}
