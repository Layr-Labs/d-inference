package faultstate

import (
	"strings"
)

// providerOutcomeIsFault classifies a FAILED provider terminal (ok==false) for
// the node-health breaker. It is intentionally implemented LOCALLY in the
// registry package: the api package owns the request-time failure classifier,
// and importing it here would create an import cycle (api already imports
// registry).
//
// Healthy sheds (returns false — never counted):
//   - client-shape failures: 429 and any 4xx (400-499, incl. 499 cancel)
//   - a capacity-class 5xx: a healthy-but-busy provider (see isCapacityShedError)
//
// Genuine faults (returns true — counted toward the breaker):
//   - a 5xx (500/502/503/504) whose message is NOT a capacity shed: a real
//     crash, internal error, model-load fault, disconnect-flush, or silent
//     timeout, and by default any such 5xx not recognized as a capacity shed
//
// Capacity-shaped 5xx are ignored regardless of the exact code: capacity rejects
// usually arrive as 503, but some/older paths surface them as 500/502/504 and
// the dispatch reclassifier turns those into uptime-neutral 429s, so counting
// them here would deroute a healthy busy node. Any other code (e.g. an
// unattributed 0/501/505) is NOT counted — conservative.
func providerOutcomeIsFault(statusCode int, errStr string) bool {
	if statusCode == 429 || (statusCode >= 400 && statusCode <= 499) {
		return false
	}
	switch statusCode {
	case 500, 502, 503, 504:
		// A 5xx whose MESSAGE names a capacity/backpressure condition is a
		// healthy-but-busy shed, not a node fault — ignore it regardless of the
		// exact status code. Capacity rejects normally arrive as 503, but some
		// (and older) provider paths surface token-budget / KV / context capacity
		// as 500/502/504, and the dispatch reclassifier already turns those into
		// uptime-neutral 429s; counting them as faults here would deroute a
		// healthy busy node. A 5xx with no capacity marker (a real crash, a
		// disconnect-flush, or a silent timeout) is a genuine fault.
		return !isCapacityShedError(errStr)
	default:
		return false
	}
}

// isNodeCapacityRejectStrike reports whether a failed terminal is a
// NODE-SCOPED capacity-shaped 5xx — the class that feeds the stable-identity
// capacity-black-hole streak (ejection.go). It is the capacity-shed
// vocabulary MINUS request-shape context overflows: an oversized prompt is
// rejected identically by every provider serving the model, so counting it
// would eject healthy nodes on a burst of oversized requests (mirrors the api
// layer's isCapacityRejectStrike carve-out). Client-shape 4xx never count.
func isNodeCapacityRejectStrike(statusCode int, errStr string) bool {
	switch statusCode {
	case 500, 502, 503, 504:
	default:
		return false
	}
	return isCapacityShedError(errStr) && !isRequestShapeContextReject(errStr)
}

// isRequestShapeContextReject reports whether a capacity-shed message names a
// context-window/length overflow — a property of the REQUEST, not the node.
// Matches both tenses ("exceeds"/"exceeded") plus the bare context markers,
// mirroring the api layer's classifyRejection/isCapacityRejectStrike.
func isRequestShapeContextReject(errStr string) bool {
	s := strings.ToLower(errStr)
	s = strings.ReplaceAll(s, "\u2019", "'")
	if strings.Contains(s, "context") &&
		(strings.Contains(s, "exceeds") || strings.Contains(s, "exceeded")) {
		return true
	}
	return strings.Contains(s, "context length") || strings.Contains(s, "context window")
}

// isCapacityShedError reports whether a failed 5xx terminal's message describes a
// healthy-but-busy capacity/lifecycle shed (which must NOT count toward the
// breaker). Matching is case-insensitive and substring-based, except "oom"
// (whole word, so "room" / "bloom" do not match) and the ("slot" AND "active")
// pair (a busy-slot shed).
func isCapacityShedError(errStr string) bool {
	s := strings.ToLower(errStr)
	for _, m := range capacityShedMarkers {
		if strings.Contains(s, m) {
			return true
		}
	}
	if containsWord(s, "oom") {
		return true
	}
	if strings.Contains(s, "slot") && strings.Contains(s, "active") {
		return true
	}
	return false
}

// containsWord reports whether word appears in s delimited by non-word
// boundaries, so a short token like "oom" matches "gpu oom" but not "boom" or
// "room". word is assumed lowercase/alphanumeric; s is already lowercased.
// (Local to the registry package; mirrors the api package's helper of the same
// name — the two live in different packages.)
func containsWord(s, word string) bool {
	for from := 0; from+len(word) <= len(s); {
		i := strings.Index(s[from:], word)
		if i < 0 {
			return false
		}
		start := from + i
		end := start + len(word)
		beforeOK := start == 0 || !isWordByte(s[start-1])
		afterOK := end == len(s) || !isWordByte(s[end])
		if beforeOK && afterOK {
			return true
		}
		from = start + 1
	}
	return false
}

func isWordByte(b byte) bool {
	return b == '_' ||
		(b >= 'a' && b <= 'z') ||
		(b >= 'A' && b <= 'Z') ||
		(b >= '0' && b <= '9')
}
