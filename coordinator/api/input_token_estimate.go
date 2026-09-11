package api

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// inputFloorPromptTokens counts only the active endpoint's prompt. Canonical
// lowering owns text joins and framing where supported. Native-only bodies keep
// their prompt estimate, because lowering is not a serving eligibility gate.
func inputFloorPromptTokens(parsed map[string]any, endpoint promptcontract.Endpoint) int {
	messages, media, err := promptcontract.PromptMessagesForEstimate(endpoint, parsed)
	if err == nil {
		return inputFloorMessageTokens(messages) + media.Images*imagePromptTokenCost + media.Videos*videoPromptTokenCost
	}
	switch endpoint {
	case promptcontract.EndpointMessages:
		tokens := inputFloorMessageTokens(parsed["messages"])
		if system := promptcontract.AnthropicSystemText(parsed["system"]); system != "" {
			tokens += 4 + textPromptTokens(system)
		}
		return tokens
	case promptcontract.EndpointResponses:
		tokens, _ := inputShape(parsed["input"])
		return tokens
	// Only the scalar/single-string shape lowered above gets chat framing.
	case promptcontract.EndpointCompletions:
		return nativeCompletionPromptTokens(parsed["prompt"])
	}
	return 0
}

// Reasoning and tool-call history are prompt content even without assistant
// prose. Count names and argument text, excluding IDs and wrapper metadata.
// Lowering normalizes Responses function_call and Anthropic tool_use into this
// same tool_calls representation. Native-only blocks retain contentShape's
// endpoint-native estimate instead.
func inputFloorMessageTokens(messages any) int {
	tokens, _ := messagesShape(messages)
	items, _ := messages.([]any)
	for _, item := range items {
		message, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if message["role"] == "assistant" {
			// These are alternative representations of one reasoning channel. Use
			// the first nonempty value rather than charging duplicate history.
			for _, key := range []string{"thinking", "reasoning", "reasoning_content"} {
				if text, ok := message[key].(string); ok && text != "" {
					tokens += textPromptTokens(text)
					break
				}
			}
		}
		calls, _ := message["tool_calls"].([]any)
		for _, raw := range calls {
			if call, ok := raw.(map[string]any); ok {
				tokens += inputFloorFunctionTokens(call["function"])
			}
		}
		if len(calls) == 0 {
			tokens += inputFloorFunctionTokens(message["function_call"])
		}
	}
	return tokens
}

func inputFloorFunctionTokens(value any) int {
	function, ok := value.(map[string]any)
	if !ok {
		return 0
	}
	name, _ := function["name"].(string)
	arguments, _ := function["arguments"].(string)
	return textPromptTokens(name) + textPromptTokens(arguments)
}

// Native completion batches contain raw text or token IDs, without chat roles.
// Empty nested batches and JSON wrappers contribute no tokens.
func nativeCompletionPromptTokens(prompt any) int {
	switch value := prompt.(type) {
	case string:
		return textPromptTokens(value)
	case []any:
		tokens := 0
		for _, part := range value {
			tokens += nativeCompletionPromptTokens(part)
		}
		return tokens
	case json.Number, int, float64:
		return 1
	default:
		return 0
	}
}
