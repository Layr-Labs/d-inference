package response

import (
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
func stripSSEDoneEvents(chunk string) (string, bool) {
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
