package api

import (
	"bytes"
	"encoding/json"
	"strings"
)

// normalizeSSEChunk fixes fields in SSE chunks to match the OpenAI spec.
// Some backends emit "content":null instead of "content":"",
// and include "usage":null which strict parsers (ForgeCode, Codex) reject
// because they expect usage to be either absent or a full object.
func normalizeSSEChunk(chunk string) string {
	line := strings.TrimPrefix(chunk, "data: ")
	// Only trigger the expensive JSON parse for fields we actually fix.
	// "finish_reason":null appears on every chunk but we don't touch it, so
	// the gates scan for the fixable `"<key>":null` shapes and the reasoning
	// aliases in a pass each (sse_normalize_gate.go) instead of one
	// strings.Contains per field.
	if !sseChunkNeedsNullFix(line) && !sseChunkHasReasoningField(line) {
		return chunk
	}
	return rewriteSSEChunkFields(chunk, line)
}

// rewriteSSEChunkFields is normalizeSSEChunk's slow path: the JSON round-trip
// that rewrites null delta fields, drops null top-level fields, mirrors the
// reasoning aliases and synthesises reasoning_details. line is chunk without
// its "data: " prefix. Returns chunk unchanged when nothing needed fixing or
// the payload is not a JSON object.
func rewriteSSEChunkFields(chunk, line string) string {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &raw); err != nil {
		return chunk
	}

	changed := false

	// Remove top-level null fields (usage, system_fingerprint, etc.)
	// ForgeCode expects usage to be absent or a full object, not null.
	for _, key := range []string{"usage", "system_fingerprint"} {
		if v, ok := raw[key]; ok && string(v) == "null" {
			delete(raw, key)
			changed = true
		}
	}

	// Fix null fields inside choices[].delta
	if choicesRaw, ok := raw["choices"]; ok {
		var choices []map[string]json.RawMessage
		if err := json.Unmarshal(choicesRaw, &choices); err == nil {
			for i, choice := range choices {
				if deltaRaw, ok := choice["delta"]; ok {
					var delta map[string]json.RawMessage
					if err := json.Unmarshal(deltaRaw, &delta); err == nil {
						deltaChanged := false
						for _, field := range []string{"content", "reasoning_content", "reasoning", "refusal"} {
							if v, ok := delta[field]; ok && string(v) == "null" {
								delta[field] = json.RawMessage(`""`)
								deltaChanged = true
							}
						}
						if v, ok := delta["tool_calls"]; ok && string(v) == "null" {
							delta["tool_calls"] = json.RawMessage(`[]`)
							deltaChanged = true
						}
						// reasoning_content is provider-canonical for streaming deltas.
						// If either alias is present, emit both with the same value, even
						// when that value is empty; empty values never produce details.
						reasoningRaw, hasReasoning := delta["reasoning"]
						reasoningContentRaw, hasReasoningContent := delta["reasoning_content"]
						reasoning := nonEmptyRawString(reasoningRaw)
						reasoningContent := nonEmptyRawString(reasoningContentRaw)
						chosenReasoning := reasoningContent
						chosenRaw := reasoningContentRaw
						if chosenReasoning == "" && reasoning != "" {
							chosenReasoning = reasoning
							chosenRaw = reasoningRaw
						} else if chosenReasoning == "" && !hasReasoningContent {
							chosenRaw = reasoningRaw
						}
						if hasReasoning || hasReasoningContent {
							if !hasReasoning || !bytes.Equal(reasoningRaw, chosenRaw) {
								delta["reasoning"] = chosenRaw
								deltaChanged = true
							}
							if !hasReasoningContent || !bytes.Equal(reasoningContentRaw, chosenRaw) {
								delta["reasoning_content"] = chosenRaw
								deltaChanged = true
							}
						}
						if _, hasDetails := delta["reasoning_details"]; !hasDetails && chosenReasoning != "" {
							choiceIndex := normalizedRawChoiceIndex(choice["index"], i)
							details, err := json.Marshal(canonicalReasoningDetails(chosenReasoning, choiceIndex))
							if err == nil {
								delta["reasoning_details"] = details
								deltaChanged = true
							}
						}
						if deltaChanged {
							choices[i]["delta"], _ = json.Marshal(delta)
							changed = true
						}
					}
				}
			}
			if changed {
				raw["choices"], _ = json.Marshal(choices)
			}
		}
	}

	if !changed {
		return chunk
	}

	out, err := json.Marshal(raw)
	if err != nil {
		return chunk
	}
	return "data: " + string(out)
}

func nonEmptyRawString(raw json.RawMessage) string {
	var value string
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil {
		return ""
	}
	return value
}

func normalizedRawChoiceIndex(raw json.RawMessage, fallback int) int {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] == '"' {
		return fallback
	}
	var index json.Number
	if json.Unmarshal(raw, &index) == nil {
		return normalizedChoiceIndex(index, fallback)
	}
	return fallback
}
