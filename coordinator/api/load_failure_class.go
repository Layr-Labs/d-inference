package api

import "strings"

// Load-failure reason buckets for the routing.load_model_rejects counter.
// The reason is derived ENTIRELY from the provider's
// load_model_status error string (protocol.LoadModelStatusMessage.Error): that
// wire message carries no status code and we deliberately add no new
// provider→coordinator field. Keep this low-cardinality set in sync with the
// dashboard query for d_inference.routing.load_model_rejects.
const (
	loadFailureInsufficientMemory = "insufficient_memory"
	loadFailureSlotCap            = "slot_cap"
	loadFailureDraining           = "draining"
	loadFailureModelNotFound      = "model_not_found"
	loadFailureOther              = "other"
)

// classifyLoadFailure maps a provider load_model_status error string to a
// low-cardinality reason tag. Matching is case-insensitive and substring-based
// because the strings are human-readable and drift across provider versions.
//
// IMPORTANT: the PROACTIVE load_model_status path sends
// error.localizedDescription for a Swift `InferenceError`, which — lacking
// LocalizedError/CustomNSError conformance — bridges to a GENERIC Foundation
// string ("The operation couldn't be completed. (…error N.)") with no reason
// text, so most proactive memory failures classify as "other" today. That is
// expected: the LoadModelStatusFailed handler applies the short backoff to ALL
// non-draining failures and does NOT gate on this classification. The
// classifier still labels the strings that ARE descriptive — the draining
// reason (sent verbatim), the dispatch-path strings, and any future descriptive
// provider strings — so the telemetry improves automatically if the provider
// starts sending richer reasons.
func classifyLoadFailure(errStr string) string {
	s := strings.ToLower(strings.TrimSpace(errStr))
	switch {
	case s == "":
		return loadFailureOther
	case strings.Contains(s, "draining"):
		// protocol.ProviderDrainingForUpdate ("provider draining for update").
		return loadFailureDraining
	case strings.Contains(s, "insufficient memory") ||
		strings.Contains(s, "insufficient kv") ||
		strings.Contains(s, "out of memory") ||
		containsWord(s, "oom"):
		// "insufficient memory to load model '…'", evictUntilAvailable's
		// "Insufficient memory (… GB free, need … GB) …", the post-load
		// "insufficient KV headroom" guard, and the documented "GPU OOM" reason.
		// "oom" is matched as a whole token so unrelated strings like
		// "…: boom" or "no room left on device" do NOT fall in this bucket.
		return loadFailureInsufficientMemory
	case strings.Contains(s, "slot") &&
		(strings.Contains(s, "active") ||
			strings.Contains(s, "cap") ||
			strings.Contains(s, "cannot load")):
		// "All N model slot(s) are active; cannot load '…'".
		return loadFailureSlotCap
	case strings.Contains(s, "not found") ||
		strings.Contains(s, "not in advertised") ||
		strings.Contains(s, "not in local") ||
		strings.Contains(s, "no such model"):
		// "Model '…' not found in local HuggingFace cache" /
		// "Model '…' not in advertised model list".
		return loadFailureModelNotFound
	default:
		// Generic/opaque strings, including the Foundation-bridged
		// localizedDescription and bare "model load failed: …".
		return loadFailureOther
	}
}

// loadFailureIsPermanent reports whether a load-failure reason will NOT recover
// when memory frees, so the pending entry should keep its full TTL cooldown
// rather than the short memory backoff. Only model_not_found qualifies today:
// the provider does not have the model, so re-attempting the load every ~30s
// inside the queue window just re-fails. Transient classes (insufficient_memory,
// slot_cap) and opaque/generic strings ("other" — which is where the proactive
// path's bridged localizedDescription for real memory pressure lands) take the
// short backoff so a provider whose memory frees is reconsidered quickly.
func loadFailureIsPermanent(reason string) bool {
	return reason == loadFailureModelNotFound
}

// containsWord reports whether word appears in s delimited by non-alphanumeric
// boundaries, so a short token like "oom" matches "gpu oom" but not "boom" or
// "room". word is assumed lowercase and alphanumeric; s is already lowercased.
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
