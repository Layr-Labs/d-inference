package service

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Some Macs reject every freshly generated key's first attestKey call with
// invalidKey, which Apple treats as App Attest being unusable on the device.
// Each retry makes the client generate another key and inflates Apple's
// per-device risk metric, so after repeated failures in a day the machine
// waits hours instead of minutes. The count is durable and time-windowed: a
// verified attestation does not reset it, and nothing here changes trust.
const (
	enrollmentInvalidKeyThreshold = 3
	enrollmentInvalidKeyWindow    = 24 * time.Hour
	enrollmentInvalidKeyBackoff   = 6 * time.Hour
	// A new session is not latency sensitive; waiting briefly for a storage
	// permit keeps a mass reconnect from skipping the resumed-backoff check.
	enrollmentBackoffPermitWait = 10 * time.Second
)

// enrollmentBackoffDue reports whether the attestation that just failed with
// apple_invalid_key makes this machine (canonical ID, else the account) reach
// the threshold in the trailing window. The current failure is already
// archived when the retry loop asks. Storage errors keep the normal backoff.
func (x *Session) enrollmentBackoffDue(failure string) bool {
	if failure != "apple_invalid_key" || x.expected != "attestation" {
		return false
	}
	release, ok := x.acquireStorage()
	if !ok {
		return false
	}
	defer release()
	times, ok := x.enrollmentInvalidKeyFailures(time.Now().UTC().Add(-enrollmentInvalidKeyWindow))
	if !ok || len(times) < enrollmentInvalidKeyThreshold {
		return false
	}
	x.s.ddIncr("app_attest.enrollment_backoff", []string{"phase:failure"})
	x.observeSideEffect("recovery", "enrollment_backoff")
	return true
}

// enrollmentBackoffRemaining is what is left of a backoff that an earlier
// session of this machine started, so a reconnect, coordinator restart or
// release cannot let it enroll another key early. It re-derives
// enrollmentBackoffDue from the archive. Storage errors start normally.
func (x *Session) enrollmentBackoffRemaining(ctx context.Context, now time.Time) time.Duration {
	release, ok := x.acquireStorageWithin(ctx, enrollmentBackoffPermitWait)
	if !ok {
		return 0
	}
	defer release()
	times, ok := x.enrollmentInvalidKeyFailures(now.Add(-enrollmentInvalidKeyBackoff - enrollmentInvalidKeyWindow))
	if !ok {
		return 0
	}
	left := enrollmentBackoffLeft(times, now)
	if left > 0 {
		x.s.ddIncr("app_attest.enrollment_backoff", []string{"phase:session_start"})
		x.observeSideEffect("recovery", "enrollment_backoff_resumed")
	}
	return left
}

// enrollmentBackoffLeft takes failure times newest first. The latest failure
// started a backoff if the window before it held the threshold, exactly as
// enrollmentBackoffDue decided when it happened.
func enrollmentBackoffLeft(times []time.Time, now time.Time) time.Duration {
	if len(times) < enrollmentInvalidKeyThreshold {
		return 0
	}
	latest, inWindow := times[0], 0
	for _, at := range times {
		if !at.Before(latest.Add(-enrollmentInvalidKeyWindow)) {
			inWindow++
		}
	}
	left := latest.Add(enrollmentInvalidKeyBackoff).Sub(now)
	if inWindow < enrollmentInvalidKeyThreshold || left <= 0 {
		return 0
	}
	// Another replica's clock running ahead cannot lengthen the backoff.
	return min(left, enrollmentInvalidKeyBackoff)
}

// enrollmentInvalidKeyFailures reads this machine's (else the account's)
// invalid-key enrollment failures. The caller holds a storage permit.
func (x *Session) enrollmentInvalidKeyFailures(since time.Time) ([]time.Time, bool) {
	failures, ok := store.As[store.AppAttestKeyRotationStore](x.s.store)
	if !ok {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	times, err := failures.AppAttestEnrollmentInvalidKeyFailureTimes(ctx, x.canonicalMachine(ctx, ""), x.account, since)
	return times, err == nil
}
