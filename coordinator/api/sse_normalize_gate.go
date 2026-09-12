package api

// Cheap pre-gates for normalizeSSEChunk. Every streamed token passes through
// the relay, so deciding whether a chunk needs the JSON round-trip must cost a
// scan or two, not one strings.Contains per fixable field.

import "strings"

// sseNullFixKeys are the JSON keys whose null values normalizeSSEChunk
// rewrites (delta fields become ""/[], top-level fields are dropped). Each is
// matched as `<key>:null` — exactly the substrings the gate has always looked
// for — so `"finish_reason":null`, present on every delta, never triggers a
// round-trip.
var sseNullFixKeys = [...]string{
	`"content":`,
	`"tool_calls":`,
	`"usage":`,
	`"reasoning":`,
	`"reasoning_content":`,
	`"refusal":`,
	`"system_fingerprint":`,
}

// sseChunkNeedsNullFix reports whether line contains `<key>:null` for any key
// in sseNullFixKeys, in a single pass: it walks the `null` literals and checks
// the bytes immediately before each one. This is equivalent to OR-ing
// strings.Contains over the seven `"<key>":null` patterns, substring semantics
// included (a match inside a string value counts, and the round-trip is then
// a no-op that returns the chunk unchanged).
func sseChunkNeedsNullFix(line string) bool {
	rest := line
	for {
		i := strings.Index(rest, "null")
		if i < 0 {
			return false
		}
		head := rest[:i]
		for _, key := range sseNullFixKeys {
			if strings.HasSuffix(head, key) {
				return true
			}
		}
		rest = rest[i+len("null"):]
	}
}

// sseChunkHasReasoningField reports whether line names a `"reasoning"` or
// `"reasoning_content"` key. One scan for the shared `"reasoning` prefix
// gates the two exact checks, so chunks carrying only `"reasoning_details"`
// or `"reasoning_tokens"` (the common no-op shapes) cost one scan and never
// round-trip.
func sseChunkHasReasoningField(line string) bool {
	if !strings.Contains(line, `"reasoning`) {
		return false
	}
	return strings.Contains(line, `"reasoning"`) || strings.Contains(line, `"reasoning_content"`)
}
