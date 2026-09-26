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
)

// enrollmentBackoffDue reports whether the attestation that just failed with
// apple_invalid_key makes this machine (canonical ID, else the account) reach
// the threshold in the trailing window. The current failure is already
// archived when the retry loop asks. Storage errors keep the normal backoff.
func (x *Session) enrollmentBackoffDue(failure string) bool {
	if failure != "apple_invalid_key" || x.expected != "attestation" {
		return false
	}
	failures, ok := store.As[store.AppAttestKeyRotationStore](x.s.store)
	if !ok {
		return false
	}
	release, ok := x.acquireStorage()
	if !ok {
		return false
	}
	defer release()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	machine := x.canonicalMachine(ctx, "")
	n, err := failures.CountAppAttestEnrollmentInvalidKeyFailures(ctx, machine, x.account, time.Now().UTC().Add(-enrollmentInvalidKeyWindow))
	if err != nil || n < enrollmentInvalidKeyThreshold {
		return false
	}
	x.s.ddIncr("app_attest.enrollment_backoff", nil)
	x.observeSideEffect("recovery", "enrollment_backoff")
	return true
}
