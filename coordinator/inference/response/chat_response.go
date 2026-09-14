package response

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func normalizeCompleteChatResponse(obj map[string]any, requestedModel string) {
	if requestedModel != "" {
		obj["model"] = requestedModel
	}
	for _, key := range []string{"system_fingerprint"} {
		if v, ok := obj[key]; ok && v == nil {
			delete(obj, key)
		}
	}
	choices, ok := obj["choices"].([]any)
	if !ok {
		return
	}
	for choicePosition, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		choiceIndex := normalizedChoiceIndex(choice["index"], choicePosition)
		if message, ok := choice["message"].(map[string]any); ok {
			normalizeCompleteMessage(message, choiceIndex)
		}
		if delta, ok := choice["delta"].(map[string]any); ok {
			normalizeCompleteMessage(delta, choiceIndex)
		}
	}
}

func buildNonStreamingResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, requestedMax int, seSignature, responseHash string) types.ChatCompletionResponse {
	message := types.ChatCompletionMessage{
		Role:    "assistant",
		Content: msg.Content,
	}
	if msg.Reasoning != "" {
		message.Reasoning = msg.Reasoning
		message.ReasoningContent = msg.Reasoning
	}
	if msg.ReasoningDetailsPresent {
		message.ReasoningDetails = msg.ReasoningDetails
	} else if msg.Reasoning != "" {
		message.ReasoningDetails = canonicalReasoningDetails(msg.Reasoning, 0)
	}

	if len(msg.ToolCalls) > 0 {
		message.ToolCalls = msg.ToolCalls
	}
	finishReason := effectiveFinishReason(msg.FinishReason, len(msg.ToolCalls) > 0, usage, requestedMax)

	resp := types.ChatCompletionResponse{
		ID:      "chatcmpl-" + requestID,
		Object:  "chat.completion",
		Created: time.Now().Unix(),
		Model:   model,
		Choices: []types.ChatCompletionChoice{{
			Index:        0,
			Message:      message,
			FinishReason: finishReason,
		}},
		Usage: types.ChatCompletionUsage{
			PromptTokens:     usage.PromptTokens,
			CompletionTokens: usage.CompletionTokens,
			TotalTokens:      usage.PromptTokens + usage.CompletionTokens,
		},
	}

	// Surface the OpenAI-standard reasoning-token breakdown when present
	// so non-streaming chat-completions consumers can read it (the
	// streaming path carries it on the provider's verbatim usage chunk).
	if rt := resolveReasoningTokens(usage, msg.Reasoning); rt > 0 {
		resp.Usage.CompletionTokensDetails = &types.CompletionTokensDetails{
			ReasoningTokens: int(rt),
		}
	}
	if usage.CachedTokens > 0 {
		resp.Usage.PromptTokensDetails = &types.PromptTokensDetails{CachedTokens: usage.CachedTokens}
	}

	if seSignature != "" {
		resp.SESignature = seSignature
		resp.ResponseHash = responseHash
	}

	return resp
}
