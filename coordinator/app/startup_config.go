package app

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"time"
)

// parseAPNsEnforceAfter reads APNS_ENFORCE_AFTER (RFC3339) — the instant at which
// code-identity attestation becomes mandatory for routing. Empty/unset returns the
// zero time, which keeps the coordinator in grace/observe mode indefinitely (the
// safe default: configuring APNs secrets never deroutes the fleet). A NON-EMPTY but
// malformed value returns an error so the caller fails startup — silently falling
// back to grace there would be a hidden enforcement downgrade on a typo.
func parseAPNsEnforceAfter() (time.Time, error) {
	raw := strings.TrimSpace(os.Getenv("APNS_ENFORCE_AFTER"))
	if raw == "" {
		// Unset is intentional: grace/observe is the safe default. Only a
		// non-empty-but-malformed value is an error (handled below).
		return time.Time{}, nil
	}
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("APNS_ENFORCE_AFTER %q is not valid RFC3339: %w", raw, err)
	}
	return t, nil
}

const (
	// maxTTFTOccupancyAlpha bounds EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA. The term
	// is alpha·occ·1000/decodeTPS ms, so an alpha above this would imply >1e6
	// decode-token-times of head-of-line wait per peer — nonsensical and almost
	// certainly a typo (e.g. a misplaced decimal), so it is rejected for the safe
	// default (0 = term off) rather than silently distorting the shadow estimate.
	maxTTFTOccupancyAlpha = 1e6
	// minTTFTDeadlineBaseMs / maxTTFTDeadlineBaseMs bound
	// EIGENINFERENCE_TTFT_DEADLINE_BASE_MS and
	// EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS. Below ~1s no first-token SLA
	// is realistic; above ~120s either gate is operationally meaningless.
	minTTFTDeadlineBaseMs = 1000.0
	maxTTFTDeadlineBaseMs = 120000.0
)

// validateTTFTOccupancyAlpha parses and bounds EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA.
// It returns (alpha, ok): ok=false means the raw value was unparseable, non-finite,
// or absurd (> maxTTFTOccupancyAlpha) and the caller should keep the default 0. A
// negative value is clamped to 0 (occupancy term disabled) and accepted (ok=true).
func validateTTFTOccupancyAlpha(raw string) (float64, bool) {
	v, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false
	}
	if v < 0 {
		return 0, true
	}
	if v > maxTTFTOccupancyAlpha {
		return 0, false
	}
	return v, true
}

// validateTTFTDeadlineBaseMs parses and range-checks either shadow or live
// first-content deadline base. It returns (baseMs, ok): ok=false means the raw
// value was unparseable, non-finite, or outside
// [minTTFTDeadlineBaseMs, maxTTFTDeadlineBaseMs], and the caller keeps its own
// default.
func validateTTFTDeadlineBaseMs(raw string) (float64, bool) {
	v, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false
	}
	if v < minTTFTDeadlineBaseMs || v > maxTTFTDeadlineBaseMs {
		return 0, false
	}
	return v, true
}
