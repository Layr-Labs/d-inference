package response

import (
	"bytes"
	"encoding/json"
)

// generatedContentJSON recognizes supported endpoint payloads, conservatively.
// Unknown shapes remain unconfirmed. This is separate from routing's permissive
// isBoilerplateChunk discriminator (which intentionally commits some terminals).
func GeneratedContentJSON(data []byte) bool { return generatedContentJSONDepth(data, 0) }

func generatedContentJSONDepth(data []byte, depth int) bool {
	if depth > 2 {
		return false
	}
	var v map[string]json.RawMessage
	if json.Unmarshal(data, &v) != nil {
		return false
	}
	text := func(raw json.RawMessage) bool { var s string; return json.Unmarshal(raw, &s) == nil && s != "" }
	var choices []map[string]json.RawMessage
	_ = json.Unmarshal(v["choices"], &choices)
	for _, c := range choices {
		if text(c["text"]) {
			return true
		}
		for _, key := range []string{"delta", "message"} {
			var d map[string]json.RawMessage
			_ = json.Unmarshal(c[key], &d)
			if text(d["content"]) || text(d["reasoning_content"]) || text(d["reasoning"]) {
				return true
			}
			var calls []json.RawMessage
			_ = json.Unmarshal(d["tool_calls"], &calls)
			if len(calls) > 0 {
				return true
			}
		}
	}
	var typ string
	_ = json.Unmarshal(v["type"], &typ)
	switch typ {
	case "response.output_text.delta", "response.reasoning_text.delta", "response.reasoning_summary_text.delta", "response.function_call_arguments.delta":
		return text(v["delta"])
	case "content_block_delta":
		var d map[string]json.RawMessage
		_ = json.Unmarshal(v["delta"], &d)
		return text(d["text"]) || text(d["thinking"]) || text(d["partial_json"])
	case "content_block_start":
		var c map[string]json.RawMessage
		_ = json.Unmarshal(v["content_block"], &c)
		var t string
		_ = json.Unmarshal(c["type"], &t)
		return t == "tool_use"
	}
	// Non-streaming Responses and Messages contain typed output/content blocks.
	for _, key := range []string{"output", "content"} {
		var blocks []map[string]json.RawMessage
		_ = json.Unmarshal(v[key], &blocks)
		for _, b := range blocks {
			if text(b["text"]) || text(b["thinking"]) {
				return true
			}
			var t string
			_ = json.Unmarshal(b["type"], &t)
			if t == "tool_use" || t == "function_call" {
				return true
			}
			if nested := b["content"]; len(nested) > 0 {
				wrapped := append([]byte(`{"content":`), nested...)
				wrapped = append(wrapped, '}')
				if generatedContentJSONDepth(wrapped, depth+1) {
					return true
				}
			}
		}
	}
	return false
}

func GeneratedContentSSE(frame []byte) bool {
	for _, line := range bytes.Split(frame, []byte{'\n'}) {
		if bytes.HasPrefix(line, []byte("data:")) && GeneratedContentJSON(bytes.TrimSpace(line[5:])) {
			return true
		}
	}
	return false
}
