package identitygate

import (
	"time"
)

// VersionHistory retains the last observed binary and its disconnect-reset
// fence. The owner serializes observations, migration, and retention checks.
type VersionHistory struct {
	version string
	resetAt time.Time
}

// VersionObservation is the reset decision consumed by fault cleanup and logs.
type VersionObservation struct {
	Previous       string
	Version        string
	ResetAt        time.Time
	SinceLastReset time.Duration
	Changed        bool
	Reset          bool
	Throttled      bool
}

// Observe dates a reset at its mutation boundary, after the owner's gate lock.
// Initial and unchanged observations never sample the clock.
func (h *VersionHistory) Observe(version string, now func() time.Time) VersionObservation {
	result := VersionObservation{Previous: h.version, Version: version, ResetAt: h.resetAt}
	if version == "" {
		return result
	}
	previous := h.version
	h.version = version
	if previous == "" || previous == version {
		return result
	}
	result.Changed = true
	at := now()
	result.SinceLastReset = at.Sub(h.resetAt)
	if !h.resetAt.IsZero() && result.SinceLastReset < identityVersionResetMinInterval {
		result.Throttled = true
		return result
	}
	h.resetAt = at
	result.ResetAt = at
	result.Reset = true
	return result
}

func (h *VersionHistory) Active(touched, now time.Time) bool {
	return h.version != "" && (now.Sub(touched) <= identityVersionRetention ||
		(!h.resetAt.IsZero() && now.Sub(h.resetAt) <= identityVersionRetention))
}

func (h *VersionHistory) Supersedes(disconnectedAt time.Time) bool {
	return !disconnectedAt.IsZero() && !h.resetAt.IsZero() && !h.resetAt.Before(disconnectedAt)
}

func (h *VersionHistory) Merge(src *VersionHistory) {
	if src == nil {
		return
	}
	if h.version == "" {
		h.version = src.version
	}
	if src.resetAt.After(h.resetAt) {
		h.resetAt = src.resetAt
	}
}
