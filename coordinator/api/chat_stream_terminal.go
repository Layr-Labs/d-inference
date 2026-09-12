package api

import (
	"encoding/json"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// parseUsageOnlyStreamChunk decodes a terminal include_usage chunk (empty choices
// + a non-null usage object, carrying the final usage and no content delta) and
// returns the parsed object. ok is false for any other chunk. Parsing here once
// lets the caller hold the object and finalize it at stream end without re-parsing.
func parseUsageOnlyStreamChunk(chunk string) (obj map[string]any, ok bool) {
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

// finalizeUsageChunk renders the held terminal usage chunk for chat-completions
// streaming: it splices the provider's authoritative reasoning count into
// completion_tokens_details (no-op when there is none), strips a null
// system_fingerprint, and rewrites the build id to the public alias — marshalling
// ONCE (obj is already parsed). Returns "" if it can't be marshalled.
func finalizeUsageChunk(obj map[string]any, usage protocol.UsageInfo, pr *registry.PendingRequest) string {
	injectReasoningDetailIntoRawUsage(obj, usage)
	injectCacheDetailIntoRawUsage(obj, usage)
	if v, present := obj["system_fingerprint"]; present && v == nil {
		delete(obj, "system_fingerprint")
	}
	if pr.PublicModel != "" && pr.PublicModel != pr.Model {
		obj["model"] = pr.PublicModel
	}
	b, err := json.Marshal(obj)
	if err != nil {
		return ""
	}
	return "data: " + string(b)
}

// parseFinishStreamChunk decodes a chunk whose choices carry a non-null
// finish_reason (the terminal content chunk). ok is false for any other
// chunk. The parsed object is held by the caller and finalized at stream end
// once the authoritative token counts are known.
func parseFinishStreamChunk(chunk string) (map[string]any, bool) {
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

// finalizeFinishChunk renders the held terminal finish chunk: when the
// authoritative completion-token count shows generation hit the max-tokens
// bound, a provider-reported "stop" is corrected to "length" (the engine
// doesn't distinguish natural stop from truncation). Also rewrites the build
// id to the public alias. Returns "" if it can't be marshalled.
func finalizeFinishChunk(obj map[string]any, usage protocol.UsageInfo, pr *registry.PendingRequest) string {
	if truncatedByMaxTokens(usage, pr.RequestedMaxTokens) {
		if choices, ok := obj["choices"].([]any); ok {
			for _, c := range choices {
				if m, ok := c.(map[string]any); ok {
					if fr, _ := m["finish_reason"].(string); fr == "stop" {
						m["finish_reason"] = "length"
					}
				}
			}
		}
	}
	if pr.PublicModel != "" && pr.PublicModel != pr.Model {
		obj["model"] = pr.PublicModel
	}
	b, err := json.Marshal(obj)
	if err != nil {
		return ""
	}
	return "data: " + string(b)
}
