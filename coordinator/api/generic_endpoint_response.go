package api

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	completionsEndpoint = "/v1/completions"
	messagesEndpoint    = "/v1/messages"
)

func genericResponseMetadata(endpoint string, parsed map[string]any) (string, []string) {
	if endpoint == messagesEndpoint {
		return endpoint, requestedMessagesStopSequences(parsed)
	}
	return endpoint, nil
}

func buildGenericEndpointResponse(
	pr *registry.PendingRequest,
	message extractedMessage,
	usage protocol.UsageInfo,
) any {
	switch pr.ConsumerEndpoint {
	case messagesEndpoint:
		return buildMessagesResponse(pr, message, usage)
	default:
		return buildCompletionsResponse(pr, message, usage)
	}
}

func buildCompletionsResponse(
	pr *registry.PendingRequest,
	message extractedMessage,
	usage protocol.UsageInfo,
) map[string]any {
	response := map[string]any{
		"id":      "cmpl-" + strings.ReplaceAll(pr.RequestID, "-", ""),
		"object":  "text_completion",
		"created": time.Now().Unix(),
		"model":   consumerModel(pr),
		"choices": []any{map[string]any{
			"index":         0,
			"text":          message.Content,
			"logprobs":      nil,
			"finish_reason": genericFinishReason(message.FinishReason, usage, pr.RequestedMaxTokens),
		}},
		"usage": completionsUsage(usage),
	}
	addResponseProof(response, pr)
	return response
}

// completionsUsage is the OpenAI usage object. Validated cache usage surfaces
// as prompt_tokens_details.cached_tokens (a subset of prompt_tokens), the
// count billed at the cache-read rate — the same shape Chat Completions uses.
func completionsUsage(usage protocol.UsageInfo) map[string]any {
	out := map[string]any{
		"prompt_tokens":     usage.PromptTokens,
		"completion_tokens": usage.CompletionTokens,
		"total_tokens":      usage.PromptTokens + usage.CompletionTokens,
	}
	if cached := billableCachedTokens(usage); cached > 0 {
		out["prompt_tokens_details"] = map[string]any{"cached_tokens": cached}
	}
	return out
}

// messagesUsage is the Anthropic usage object. Anthropic counts cache reads
// separately from input_tokens (total input = input_tokens +
// cache_read_input_tokens), so a validated cache hit moves those prompt
// tokens from input_tokens to cache_read_input_tokens.
func messagesUsage(usage protocol.UsageInfo) map[string]any {
	cached := billableCachedTokens(usage)
	out := map[string]any{
		"input_tokens":  usage.PromptTokens - cached,
		"output_tokens": usage.CompletionTokens,
	}
	if cached > 0 {
		out["cache_read_input_tokens"] = cached
	}
	return out
}

func buildMessagesResponse(
	pr *registry.PendingRequest,
	message extractedMessage,
	usage protocol.UsageInfo,
) map[string]any {
	stopReason, stopSequence := messagesStopOutcome(
		message.FinishReason, usage, pr.RequestedMaxTokens, pr.MatchedStopSequence)
	content := make([]any, 0, 1+len(message.ToolCalls))
	if message.Content != "" {
		content = append(content, map[string]any{
			"type": "text",
			"text": message.Content,
		})
	}
	for _, toolCall := range message.ToolCalls {
		content = append(content, messagesToolUseBlock(toolCall))
	}
	response := map[string]any{
		"id":            "msg_" + strings.ReplaceAll(pr.RequestID, "-", ""),
		"type":          "message",
		"role":          "assistant",
		"model":         consumerModel(pr),
		"content":       content,
		"stop_reason":   stopReason,
		"stop_sequence": stopSequence,
		"usage":         messagesUsage(usage),
	}
	addResponseProof(response, pr)
	return response
}

func messagesToolUseBlock(toolCall map[string]any) map[string]any {
	id, _ := toolCall["id"].(string)
	function, _ := toolCall["function"].(map[string]any)
	name, _ := function["name"].(string)
	arguments, _ := function["arguments"].(string)
	input := map[string]any{}
	if arguments != "" {
		_ = json.Unmarshal([]byte(arguments), &input)
	}
	return map[string]any{
		"type":  "tool_use",
		"id":    id,
		"name":  name,
		"input": input,
	}
}

func genericFinishReason(reason string, usage protocol.UsageInfo, maxTokens int) string {
	if maxTokens > 0 && usage.CompletionTokens >= maxTokens {
		return "length"
	}
	if reason == "" {
		return "stop"
	}
	return reason
}

func addResponseProof(response map[string]any, pr *registry.PendingRequest) {
	if pr.SESignature == "" {
		return
	}
	response["se_signature"] = pr.SESignature
	response["response_hash"] = pr.ResponseHash
}
