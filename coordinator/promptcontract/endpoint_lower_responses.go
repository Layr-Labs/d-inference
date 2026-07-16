package promptcontract

import (
	"encoding/json"
	"strconv"
	"strings"
)

func lowerResponses(input map[string]any) (map[string]any, error) {
	rawInput, ok := input["input"]
	if !ok {
		return nil, ErrEndpointBodyInvalid
	}
	messages, err := lowerResponsesMessages(rawInput)
	if err != nil {
		return nil, err
	}

	output := cloneObject(input)
	for _, key := range []string{"input", "endpoint", "max_output_tokens", "text"} {
		delete(output, key)
	}
	output["messages"] = messages
	if tokens, ok := firstExplicitMaxTokens(input); ok {
		output["max_tokens"] = json.Number(strconv.FormatUint(tokens, 10))
	}
	if tools, present, err := lowerResponsesTools(input["tools"]); err != nil {
		return nil, err
	} else if present {
		output["tools"] = tools
	}
	if choice, present, err := lowerResponsesToolChoice(input["tool_choice"]); err != nil {
		return nil, err
	} else if present {
		output["tool_choice"] = choice
	}
	if format, ok := lowerResponsesTextFormat(input["text"]); ok {
		output["response_format"] = format
	}
	return output, nil
}

func lowerResponsesMessages(input any) ([]any, error) {
	if text, ok := input.(string); ok {
		return []any{map[string]any{"role": "user", "content": text}}, nil
	}
	items, ok := input.([]any)
	if !ok {
		return nil, ErrEndpointBodyInvalid
	}
	messages := make([]any, 0, len(items))
	for _, value := range items {
		item, ok := value.(map[string]any)
		if !ok {
			continue
		}
		kind, hasKind := item["type"].(string)
		if hasKind {
			switch kind {
			case "message":
				role, ok := item["role"].(string)
				if !ok {
					role = "user"
				}
				role, ok = canonicalRole(role)
				if !ok {
					return nil, ErrEndpointBodyInvalid
				}
				messages = append(messages, map[string]any{
					"role": role, "content": responsesContentText(item["content"]),
				})
			case "function_call":
				callID, _ := item["call_id"].(string)
				if _, exists := item["call_id"]; !exists {
					callID, _ = item["id"].(string)
				} else if _, isString := item["call_id"].(string); !isString {
					callID, _ = item["id"].(string)
				}
				name, _ := item["name"].(string)
				arguments, _ := item["arguments"].(string)
				messages = append(messages, map[string]any{
					"role": "assistant", "content": "",
					"tool_calls": []any{map[string]any{
						"id": callID, "type": "function",
						"function": map[string]any{"name": name, "arguments": arguments},
					}},
				})
			case "function_call_output":
				callID, _ := item["call_id"].(string)
				messages = append(messages, map[string]any{
					"role": "tool", "tool_call_id": callID,
					"content": responsesContentText(item["output"]),
				})
			case "reasoning":
			default:
				return nil, ErrEndpointBodyUnsupported
			}
			continue
		}

		role, ok := item["role"].(string)
		if !ok {
			continue
		}
		role, ok = canonicalRole(role)
		if !ok {
			return nil, ErrEndpointBodyInvalid
		}
		messages = append(messages, map[string]any{
			"role": role, "content": responsesContentText(item["content"]),
		})
	}
	if len(messages) == 0 {
		return nil, ErrEndpointBodyInvalid
	}
	return messages, nil
}

func responsesContentText(content any) string {
	switch content := content.(type) {
	case nil:
		return ""
	case string:
		return content
	case []any:
		texts := make([]string, 0, len(content))
		for _, part := range content {
			switch part := part.(type) {
			case string:
				if part != "" {
					texts = append(texts, part)
				}
			case map[string]any:
				if text, ok := part["text"].(string); ok && text != "" {
					texts = append(texts, text)
					continue
				}
				switch part["type"] {
				case "input_image":
					texts = append(texts, "[input_image omitted]")
				case "input_file":
					texts = append(texts, "[input_file omitted]")
				}
			}
		}
		return strings.Join(texts, "\n")
	default:
		encoded, _ := marshalEndpointJSON(content)
		return string(encoded)
	}
}

func lowerResponsesTools(raw any) ([]any, bool, error) {
	items, ok := raw.([]any)
	if !ok {
		return nil, false, nil
	}
	output := make([]any, 0, len(items))
	for _, item := range items {
		tool, ok := item.(map[string]any)
		if !ok {
			continue
		}
		kind, _ := tool["type"].(string)
		if kind != "" && kind != "function" {
			return nil, false, ErrEndpointBodyUnsupported
		}
		if function, ok := tool["function"].(map[string]any); ok {
			output = append(output, map[string]any{"type": "function", "function": function})
			continue
		}
		name, ok := nonEmptyString(tool["name"])
		if !ok {
			return nil, false, ErrEndpointBodyInvalid
		}
		function := map[string]any{"name": name}
		for _, key := range []string{"description", "parameters"} {
			if value, exists := tool[key]; exists {
				function[key] = value
			}
		}
		output = append(output, map[string]any{"type": "function", "function": function})
	}
	return output, len(output) > 0, nil
}

func lowerResponsesToolChoice(raw any) (any, bool, error) {
	if raw == nil {
		return nil, false, nil
	}
	choice, ok := raw.(map[string]any)
	if !ok {
		return raw, true, nil
	}
	if choice["type"] != "function" {
		return raw, true, nil
	}
	name, ok := nonEmptyString(choice["name"])
	if !ok {
		return nil, false, ErrEndpointBodyInvalid
	}
	return map[string]any{
		"type": "function", "function": map[string]any{"name": name},
	}, true, nil
}

func lowerResponsesTextFormat(raw any) (any, bool) {
	text, ok := raw.(map[string]any)
	if !ok {
		return nil, false
	}
	format, ok := text["format"].(map[string]any)
	if !ok {
		return nil, false
	}
	switch format["type"] {
	case "json_object":
		return map[string]any{"type": "json_object"}, true
	case "json_schema":
		return map[string]any{"type": "json_schema", "json_schema": format}, true
	default:
		return nil, false
	}
}

func firstExplicitMaxTokens(input map[string]any) (uint64, bool) {
	for _, key := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		number, ok := input[key].(json.Number)
		if !ok {
			continue
		}
		value, err := strconv.ParseUint(string(number), 10, 64)
		if err == nil && value > 0 {
			return value, true
		}
	}
	return 0, false
}
