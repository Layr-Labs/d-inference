package attempt

import (
	"strings"
)

// IsCapacityRejectStrike reports whether a provider rejection should count
// toward the capacity-reject routing cooldown (registry.RecordCapacityReject —
// the black-hole breaker). It is BUCKET A (capacity-class) MINUS the
// request-shape rejections that indict the REQUEST rather than the provider:
// an explicit context-window/length overflow is deterministic for the MODEL
// (every provider rejects that prompt identically), so counting it would cool
// down healthy providers on a burst of oversized requests.
//
// Node-scoped capacity flavors all count — "exceeds active token budget",
// "requires N tokens but only M available", "insufficient KV headroom",
// "request exceeds batch token budget", "queue full", "draining", cold "not
// loaded" misses, … For the SAME (provider, model) pair, threshold-many of
// those inside the window with ZERO interleaved accepts is the black-hole
// signature this cooldown exists for (2026-07 incident: 7 boxes rejecting
// 100% of dispatches with "token_budget_exhausted" from their first request,
// ~9k rejections/30min, zero successes — invisible to reputation and to both
// fault breakers, which deliberately skip capacity-class errors). "batch token
// budget" is deliberately INCLUDED even though ClassifyRejection may treat it
// as deterministic for FAILOVER purposes: a pair emitting it repeatedly for
// differently-sized prompts with zero accepts is exactly the misreported-
// budget pathology; a rare false trip costs one pair a bounded, re-probed TTL.
//
// Matching mirrors IsCapacityClassProviderError (substring, case-insensitive,
// curly-apostrophe-normalised). The registry enforces the zero-interleaved-
// accepts discriminator; this function only answers "is this reject about the
// provider's capacity?".
func IsCapacityRejectStrike(errStr string) bool {
	if !IsCapacityClassProviderError(errStr) {
		return false
	}
	s := strings.ToLower(strings.TrimSpace(errStr))
	s = strings.ReplaceAll(s, "’", "'")
	// Request-shape deterministic: the prompt is too big for the MODEL itself
	// (both tenses + the bare context markers, mirroring ClassifyRejection).
	// These reject identically fleet-wide and say nothing about this provider.
	if strings.Contains(s, "context") &&
		(strings.Contains(s, "exceeds") || strings.Contains(s, "exceeded")) {
		return false
	}
	if strings.Contains(s, "context length") || strings.Contains(s, "context window") {
		return false
	}
	return true
}

// IsColdModelMissRejection reports whether a capacity-class rejection is the
// BENIGN cold "model not loaded" lifecycle miss (a lazy load on first touch),
// as opposed to a genuine capacity/token-budget shed. Matching mirrors the
// "not loaded" / "no model loaded" markers in capacityClassMarkers (substring,
// case-insensitive, curly-apostrophe-normalised).
//
// A cold miss must still feed the black-hole cooldown (a box that 404s FOREVER
// with zero accepts is a black hole — RecordCapacityRejectLifecycle keeps
// feeding it) but must NOT derate the pair's gray-box capacity-503 RATE: that
// window has no accept-reset, so counting a healthy box's normal reloads would
// penalize it as if its reported budget were dishonest. Callers gate on this
// AFTER IsCapacityRejectStrike (a non-capacity "model not found" never reaches
// here).
func IsColdModelMissRejection(errStr string) bool {
	s := strings.ToLower(strings.TrimSpace(errStr))
	s = strings.ReplaceAll(s, "’", "'")
	return strings.Contains(s, "not loaded") || strings.Contains(s, "no model loaded")
}
