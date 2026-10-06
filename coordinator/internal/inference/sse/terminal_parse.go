package sse

import (
	"encoding/json"
	"strings"
)

// parseUsageOnlyStreamChunk decodes a terminal include_usage chunk (empty choices
// + a non-null usage object, carrying the final usage and no content delta) and
// returns the parsed object. ok is false for any other chunk. Parsing here once
// lets the caller hold the object and finalize it at stream end without re-parsing.
func ParseUsageOnlyStreamChunk(chunk string) (obj map[string]any, ok bool) {
	line := strings.TrimPrefix(chunk, "data: ")
	// Cheap gate: skip the parse for content deltas and usage:null chunks.
	if !strings.Contains(line, `"usage"`) || strings.Contains(line, `"usage":null`) {
		return nil, false
	}
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		return nil, false
	}
	if u, uok := obj["usage"].(map[string]any); !uok || u == nil {
		return nil, false
	}
	if choices, _ := obj["choices"].([]any); len(choices) != 0 {
		return nil, false
	}
	return obj, true
}

// parseFinishStreamChunk decodes a chunk whose choices carry a non-null
// finish_reason (the terminal content chunk). ok is false for any other
// chunk. The parsed object is held by the caller and finalized at stream end
// once the authoritative token counts are known.
func ParseFinishStreamChunk(chunk string) (map[string]any, bool) {
	line := strings.TrimPrefix(chunk, "data: ")
	if !strings.Contains(line, `"finish_reason":"`) {
		return nil, false
	}
	var obj map[string]any
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		return nil, false
	}
	choices, _ := obj["choices"].([]any)
	for _, c := range choices {
		if m, ok := c.(map[string]any); ok {
			if fr, _ := m["finish_reason"].(string); fr != "" {
				return obj, true
			}
		}
	}
	return nil, false
}
