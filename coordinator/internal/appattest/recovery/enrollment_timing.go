package recovery

import (
	"time"
)

// Some Macs reject every freshly generated key's first attestKey call with
// invalidKey, which Apple treats as App Attest being unusable on the device.
// Each retry makes the client generate another key and inflates Apple's
// per-device risk metric, so after repeated failures in a day the machine
// waits hours instead of minutes. The count is durable and time-windowed: a
// verified attestation does not reset it, and nothing here changes trust.
const (
	EnrollmentInvalidKeyThreshold = 3
	EnrollmentInvalidKeyWindow    = 24 * time.Hour
	EnrollmentInvalidKeyBackoff   = 6 * time.Hour
	// A new session is not latency sensitive; waiting briefly for a storage
	// permit keeps a mass reconnect from skipping the resumed-backoff check.
	EnrollmentPermitWait = 10 * time.Second
)

// enrollmentBackoffLeft takes failure times newest first. The latest failure
// started a backoff if the window before it held the threshold, exactly as
// enrollmentBackoffDue decided when it happened.
func EnrollmentBackoffLeft(times []time.Time, now time.Time) time.Duration {
	if len(times) < EnrollmentInvalidKeyThreshold {
		return 0
	}
	latest, inWindow := times[0], 0
	for _, at := range times {
		if !at.Before(latest.Add(-EnrollmentInvalidKeyWindow)) {
			inWindow++
		}
	}
	left := latest.Add(EnrollmentInvalidKeyBackoff).Sub(now)
	if inWindow < EnrollmentInvalidKeyThreshold || left <= 0 {
		return 0
	}
	// Another replica's clock running ahead cannot lengthen the backoff.
	return min(left, EnrollmentInvalidKeyBackoff)
}
