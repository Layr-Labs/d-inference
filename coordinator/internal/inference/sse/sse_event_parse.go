package sse

import (
	"encoding/json"
	"strings"
)

func isSSEDoneEventGroup(group string) bool {
	lines := strings.Split(group, "\n")
	data := make([]string, 0, len(lines))
	for _, line := range lines {
		if value, ok := sseDataValue(line); ok {
			data = append(data, value)
		}
	}
	if len(data) > 0 {
		return strings.TrimSpace(strings.Join(data, "\n")) == "[DONE]"
	}
	return len(lines) == 1 &&
		strings.TrimSpace(strings.TrimPrefix(group, "\uFEFF")) == "[DONE]"
}

// stripSSEDoneEvents removes provider-owned SSE terminators while preserving
// sibling events in the same chunk. The coordinator owns stream termination so
// authoritative usage, signature, and metadata events always precede [DONE].
func StripSSEDoneEvents(chunk string) (string, bool) {
	if !strings.Contains(chunk, "[DONE]") {
		return chunk, false
	}
	normalized := strings.ReplaceAll(strings.ReplaceAll(chunk, "\r\n", "\n"), "\r", "\n")
	groups := strings.Split(normalized, "\n\n")
	kept := make([]string, 0, len(groups))
	removed := false
	for _, group := range groups {
		if isSSEDoneEventGroup(group) {
			removed = true
			continue
		}
		kept = append(kept, group)
	}
	if !removed {
		return chunk, false
	}
	return strings.Join(kept, "\n\n"), true
}

// isResponsesAPIEventChunk reports whether a streamed chunk is a Responses API
// SSE event (its parsed top-level "type" is a "response.*" event). It parses
// rather than substring-matches: a chat.completion content delta whose text
// quotes "response.created"/"response.output_text.delta" (e.g. a user asking
// about the Responses API) must NOT be misread as a Responses stream, which
// would make the relay skip chat-completions termination handling (usage
// splicing, [DONE] swallowing, normalizeSSEChunk) and corrupt the stream.
func IsResponsesAPIEventChunk(chunk string) bool {
	line := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(chunk), "data:"))
	// Cheap gate: every Responses event names a response.* type at top level.
	if !strings.Contains(line, `"response.`) {
		return false
	}
	var ev struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal([]byte(line), &ev); err != nil {
		return false
	}
	return strings.HasPrefix(ev.Type, "response.")
}
