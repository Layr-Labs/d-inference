package api

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

func validateToolHistory(raw any) error {
	if raw == nil {
		return nil
	}
	messages, ok := raw.([]any)
	if !ok {
		return invalidToolConstraint("messages must be an array", "messages")
	}
	outstanding := make(map[string]struct{})
	lastDeclaration := -1
	for index, rawMessage := range messages {
		message, ok := rawMessage.(map[string]any)
		if !ok {
			return invalidToolConstraint("messages entries must be objects", "messages")
		}
		role, _ := message["role"].(string)
		if role == "tool" {
			id, _ := message["tool_call_id"].(string)
			if id == "" {
				return invalidToolConstraint("tool message requires tool_call_id", fmt.Sprintf("messages[%d].tool_call_id", index))
			}
			if _, exists := outstanding[id]; !exists {
				return invalidToolConstraint("tool message has no preceding assistant tool call", fmt.Sprintf("messages[%d].tool_call_id", index))
			}
			delete(outstanding, id)
			continue
		}
		if len(outstanding) > 0 {
			return invalidToolConstraint("assistant tool calls must be answered before the next message", "messages")
		}
		if role != "assistant" {
			continue
		}
		rawCalls, exists := message["tool_calls"]
		if !exists || rawCalls == nil {
			continue
		}
		calls, ok := rawCalls.([]any)
		if !ok {
			return invalidToolConstraint("assistant tool_calls must be an array", fmt.Sprintf("messages[%d].tool_calls", index))
		}
		for callIndex, rawCall := range calls {
			call, ok := rawCall.(map[string]any)
			if !ok {
				return invalidToolConstraint("assistant tool_calls entries must be objects", "messages")
			}
			id, _ := call["id"].(string)
			if id == "" {
				return invalidToolConstraint("assistant tool call requires id", fmt.Sprintf("messages[%d].tool_calls[%d].id", index, callIndex))
			}
			if _, duplicate := outstanding[id]; duplicate {
				return invalidToolConstraint("assistant tool call ids must be unique", "messages")
			}
			function, ok := call["function"].(map[string]any)
			if !ok {
				return invalidToolConstraint("assistant tool call requires function", "messages")
			}
			name, _ := function["name"].(string)
			if !toolFunctionNamePattern.MatchString(name) {
				return invalidToolConstraint("historical tool function name is invalid", "messages")
			}
			if err := validateHistoricalArguments(function["arguments"]); err != nil {
				return err
			}
			outstanding[id] = struct{}{}
		}
		if len(calls) > 0 {
			lastDeclaration = index
		}
	}
	// A terminal assistant tool-call turn is a supported continuation shape:
	// Gemma's template has an explicit tool-call-terminal branch. Once any
	// later message exists, every declared call must already have a result.
	if len(outstanding) > 0 && lastDeclaration != len(messages)-1 {
		return invalidToolConstraint("assistant tool calls are missing tool results", "messages")
	}
	return nil
}

func validateHistoricalArguments(raw any) error {
	if raw == nil {
		return invalidToolConstraint(
			"tool_calls[].function.arguments must be a JSON object string", "messages")
	}
	text, ok := raw.(string)
	if !ok {
		return invalidToolConstraint(
			"tool_calls[].function.arguments must be a JSON object string", "messages")
	}
	if strings.TrimSpace(text) == "" {
		return nil
	}
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	var object map[string]any
	if err := decoder.Decode(&object); err != nil || object == nil {
		return invalidToolConstraint("tool_calls[].function.arguments must be a JSON object", "messages")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return invalidToolConstraint("tool_calls[].function.arguments must be a JSON object", "messages")
	}
	return nil
}
