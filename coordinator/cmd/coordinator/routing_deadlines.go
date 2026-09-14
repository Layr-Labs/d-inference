package main

import (
	"log/slog"
	"math"
	"os"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
)

func configureModelDeadlines(logger *slog.Logger) {
	// Exact-model first-content deadline base overrides
	// ("<model>=<upstream_ms>,...", 0/"off" removes an entry so the model
	// falls back to the global base). The built-in table (Qwen3-VL 5s/4s) can
	// only tighten the global base — during the 2026-09-01 incident that
	// hardcoding killed ~47% of vision traffic with no operator recourse.
	if v := os.Getenv("EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES"); v != "" {
		if replaced, removed := modelpolicy.SetFirstContentBasesFromEnv(v); replaced+removed > 0 {
			logger.Info("exact-model first-content deadline bases overridden via EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES",
				"replaced", replaced, "removed", removed, "value", v)
		} else {
			logger.Warn("invalid EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES; using built-in table", "value", v)
		}
	}
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
