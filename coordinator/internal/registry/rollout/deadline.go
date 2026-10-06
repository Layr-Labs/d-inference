// Package rollout evaluates enforcement deadlines against the caller's clock.
package rollout

import "time"

// CodeAttestationRequired keeps an unconfigured or undated policy in grace.
func CodeAttestationRequired(configured bool, deadline, now time.Time) bool {
	if !configured || deadline.IsZero() {
		return false
	}
	return !now.Before(deadline)
}

// ReleaseEvidenceRequired treats a zero enforce-after time as immediate.
func ReleaseEvidenceRequired(enforced bool, enforceAfter, now time.Time) bool {
	return enforced && !now.Before(enforceAfter)
}
