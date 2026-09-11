package api

import (
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
	case promptcontract.EndpointCompletions:
		if prompts, ok := parsed["prompt"].([]any); ok {
			tokens := 0
			for _, prompt := range prompts {
				if text, ok := prompt.(string); ok {
					tokens += 4 + textPromptTokens(text)
				} else {
					tokens += approximateTokenCount(prompt)
				}
			}
			return tokens
		}
	}
	return 0
}

// Tool-call history is prompt content even when an assistant message has no
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
