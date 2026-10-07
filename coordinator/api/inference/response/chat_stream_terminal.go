package response

import (
	"encoding/json"

	responsepolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/responsepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// finalizeUsageChunk renders the held terminal usage chunk for chat-completions
// streaming: it splices the provider's authoritative reasoning count into
// completion_tokens_details (no-op when there is none), strips a null
// system_fingerprint, and rewrites the build id to the public alias — marshalling
// ONCE (obj is already parsed). Returns "" if it can't be marshalled.
func FinalizeUsageChunk(obj map[string]any, usage protocol.UsageInfo, pr *registry.PendingRequest) string {
	InjectReasoningDetailIntoRawUsage(obj, usage)
	InjectCacheDetailIntoRawUsage(obj, usage)
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

// finalizeFinishChunk renders the held terminal finish chunk: when the
// authoritative completion-token count shows generation hit the max-tokens
// bound, a provider-reported "stop" is corrected to "length" (the engine
// doesn't distinguish natural stop from truncation). Also rewrites the build
// id to the public alias. Returns "" if it can't be marshalled.
func FinalizeFinishChunk(obj map[string]any, usage protocol.UsageInfo, pr *registry.PendingRequest) string {
	if responsepolicy.TruncatedByMaxTokens(usage, pr.RequestedMaxTokens) {
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
