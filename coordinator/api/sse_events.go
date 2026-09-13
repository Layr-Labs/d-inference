package api

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

// isResponsesAPIEventChunk reports whether a streamed chunk is a Responses API
// SSE event (its parsed top-level "type" is a "response.*" event). It parses
// rather than substring-matches: a chat.completion content delta whose text
// quotes "response.created"/"response.output_text.delta" (e.g. a user asking
// about the Responses API) must NOT be misread as a Responses stream, which
// would make the relay skip chat-completions termination handling (usage
// splicing, [DONE] swallowing, normalizeSSEChunk) and corrupt the stream.
func isResponsesAPIEventChunk(chunk string) bool {
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

// isBoilerplateChunk reports whether a streamed provider chunk carries no
// consumer-visible output yet: the preamble emitted BEFORE the failure-prone
// work (media decode, template render, vision prefill) begins. The dispatch
// loop holds such chunks instead of committing on them, so a provider that
// dies after its preamble is retried invisibly instead of surfacing an
// in-band SSE error with zero retries.
//
// Boilerplate is exactly:
//   - a chat.completion.chunk whose choices[].delta carries ONLY the assistant
//     role — content/reasoning/refusal absent, null, or "" (some backends ride
//     an empty content along with the role), tool_calls absent/null/empty,
//     finish_reason null, no usage object; or
//   - a Responses API response.created / response.in_progress lifecycle event
//     (the parsed top-level "type" equals exactly one of those — NOT a mere
//     substring match: a chat content delta whose text quotes "response.created"
//     must still commit).
//
// Everything else — content or tool_call deltas, finish chunks, usage-only
// chunks, [DONE], complete responses, unparseable data — commits the dispatch.
func isBoilerplateChunk(chunk string) bool {
	line := strings.TrimPrefix(strings.TrimPrefix(chunk, "data: "), "data:")
	line = strings.TrimSpace(line)
	// Responses API lifecycle preamble: classify ONLY when the parsed top-level
	// "type" is exactly response.created / response.in_progress. A chat content
	// delta that merely mentions that text (e.g. a user asking about the
	// Responses API) parses as a chat.completion.chunk and falls through to the
	// role-only logic below — it is NOT boilerplate.
	if strings.Contains(line, `"response.created"`) || strings.Contains(line, `"response.in_progress"`) {
		var ev struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal([]byte(line), &ev); err == nil {
			if ev.Type == "response.created" || ev.Type == "response.in_progress" {
				return true
			}
		}
	}
	// Cheap gate: the role preamble always names the role; chunks that can't
	// be it (content deltas, finish chunks, [DONE], garbage) skip the parse.
	if !strings.Contains(line, `"role"`) {
		return false
	}
	var parsed struct {
		Object  string          `json:"object"`
		Usage   json.RawMessage `json:"usage"`
		Choices []struct {
			Delta        map[string]json.RawMessage `json:"delta"`
			FinishReason *string                    `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(line), &parsed); err != nil {
		return false
	}
	if parsed.Object != "chat.completion.chunk" {
		return false
	}
	if len(parsed.Usage) > 0 && string(parsed.Usage) != "null" {
		return false
	}
	if len(parsed.Choices) == 0 {
		return false
	}
	for _, choice := range parsed.Choices {
		if choice.FinishReason != nil {
			return false
		}
		if _, hasRole := choice.Delta["role"]; !hasRole {
			return false
		}
		for field, v := range choice.Delta {
			switch field {
			case "role":
				// The preamble itself.
			case "content", "reasoning_content", "reasoning", "refusal":
				if s := string(v); s != `""` && s != "null" {
					return false
				}
			case "tool_calls":
				if s := string(v); s != "null" && s != "[]" {
					return false
				}
			default:
				// Unknown delta payload — assume it's real output.
				return false
			}
		}
	}
	return true
}
