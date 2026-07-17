package promptcontract

import "strings"

func lowerMessages(input map[string]any) (map[string]any, error) {
	rawMessages, ok := input["messages"].([]any)
	if !ok {
		return nil, ErrEndpointBodyInvalid
	}
	messages := make([]any, 0, len(rawMessages)+1)
	if system, exists := input["system"]; exists {
		if text := anthropicContentText(system); text != "" {
			messages = append(messages, map[string]any{"role": "system", "content": text})
		}
	}
	for _, raw := range rawMessages {
		message, ok := raw.(map[string]any)
		if !ok {
			return nil, ErrEndpointBodyInvalid
		}
		role, ok := message["role"].(string)
		if !ok {
			return nil, ErrEndpointBodyInvalid
		}
		content := message["content"]
		if parts, ok := content.([]any); ok {
			switch role {
			case "assistant":
				lowered, err := lowerAnthropicAssistant(parts)
				if err != nil {
					return nil, err
				}
				messages = append(messages, lowered)
			case "user":
				if err := lowerAnthropicUser(parts, &messages); err != nil {
					return nil, err
				}
			default:
				return nil, ErrEndpointBodyInvalid
			}
		} else if role == "user" || role == "assistant" {
			messages = append(messages, map[string]any{
				"role": role, "content": anthropicContentText(content),
			})
		} else {
			return nil, ErrEndpointBodyInvalid
		}
	}

	output := cloneObject(input)
	delete(output, "system")
	delete(output, "endpoint")
	delete(output, "stop_sequences")
	output["messages"] = messages
	rawStops, hasStops := input["stop_sequences"]
	if stops, present, err := lowerAnthropicStopSequences(rawStops, hasStops); err != nil {
		return nil, err
	} else if present {
		output["stop"] = stops
	}
	rawTools, hasTools := input["tools"]
	if tools, present, err := lowerAnthropicTools(rawTools, hasTools); err != nil {
		return nil, err
	} else if present {
		output["tools"] = tools
	}
	rawChoice, hasChoice := input["tool_choice"]
	if choice, present, err := lowerAnthropicToolChoice(rawChoice, hasChoice); err != nil {
		return nil, err
	} else if present {
		output["tool_choice"] = choice
	}
	return output, nil
}

func lowerAnthropicStopSequences(raw any, exists bool) ([]any, bool, error) {
	if !exists {
		return nil, false, nil
	}
	stops, ok := raw.([]any)
	if !ok {
		return nil, false, ErrEndpointBodyInvalid
	}
	for _, stop := range stops {
		if _, ok := stop.(string); !ok {
			return nil, false, ErrEndpointBodyInvalid
		}
	}
	return stops, true, nil
}

func lowerAnthropicAssistant(parts []any) (any, error) {
	var texts, reasoning []string
	calls := make([]any, 0)
	for _, raw := range parts {
		part, ok := raw.(map[string]any)
		if !ok {
			return nil, ErrEndpointBodyInvalid
		}
		switch part["type"] {
		case "text":
			if text, ok := part["text"].(string); ok {
				texts = append(texts, text)
			}
		case "thinking":
			if text, ok := part["thinking"].(string); ok {
				reasoning = append(reasoning, text)
			}
		case "tool_use":
			id, idOK := nonEmptyString(part["id"])
			name, nameOK := nonEmptyString(part["name"])
			if !idOK || !nameOK {
				return nil, ErrEndpointBodyInvalid
			}
			arguments := part["input"]
			if _, exists := part["input"]; !exists {
				arguments = map[string]any{}
			}
			encoded, err := marshalEndpointJSON(arguments)
			if err != nil {
				return nil, ErrEndpointBodyInvalid
			}
			calls = append(calls, map[string]any{
				"id": id, "type": "function",
				"function": map[string]any{"name": name, "arguments": string(encoded)},
			})
		default:
			return nil, ErrEndpointBodyUnsupported
		}
	}
	message := map[string]any{"role": "assistant", "content": strings.Join(texts, "")}
	if len(reasoning) > 0 {
		message["reasoning_content"] = strings.Join(reasoning, "")
	}
	if len(calls) > 0 {
		message["tool_calls"] = calls
	}
	return message, nil
}

func lowerAnthropicUser(parts []any, messages *[]any) error {
	pending := make([]string, 0)
	flush := func() {
		if len(pending) == 0 {
			return
		}
		*messages = append(*messages, map[string]any{
			"role": "user", "content": strings.Join(pending, ""),
		})
		pending = pending[:0]
	}
	for _, raw := range parts {
		part, ok := raw.(map[string]any)
		if !ok {
			return ErrEndpointBodyInvalid
		}
		switch part["type"] {
		case "text":
			if text, ok := part["text"].(string); ok {
				pending = append(pending, text)
			}
		case "tool_result":
			flush()
			callID, ok := nonEmptyString(part["tool_use_id"])
			if !ok {
				return ErrEndpointBodyInvalid
			}
			*messages = append(*messages, map[string]any{
				"role": "tool", "tool_call_id": callID,
				"content": anthropicContentText(part["content"]),
			})
		default:
			return ErrEndpointBodyUnsupported
		}
	}
	flush()
	return nil
}

func anthropicContentText(value any) string {
	switch value := value.(type) {
	case string:
		return value
	case []any:
		texts := make([]string, 0, len(value))
		for _, raw := range value {
			part, ok := raw.(map[string]any)
			if !ok || part["type"] != "text" {
				continue
			}
			if text, ok := part["text"].(string); ok {
				texts = append(texts, text)
			}
		}
		return strings.Join(texts, "\n")
	default:
		return ""
	}
}

func lowerAnthropicTools(raw any, exists bool) ([]any, bool, error) {
	if !exists {
		return nil, false, nil
	}
	tools, ok := raw.([]any)
	if !ok {
		return nil, false, ErrEndpointBodyInvalid
	}
	output := make([]any, 0, len(tools))
	for _, rawTool := range tools {
		tool, ok := rawTool.(map[string]any)
		if !ok {
			return nil, false, ErrEndpointBodyInvalid
		}
		name, ok := nonEmptyString(tool["name"])
		if !ok {
			return nil, false, ErrEndpointBodyInvalid
		}
		description := any("")
		if value, exists := tool["description"]; exists {
			description = value
		}
		parameters := any(map[string]any{"type": "object"})
		if value, exists := tool["input_schema"]; exists {
			parameters = value
		}
		output = append(output, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": name, "description": description, "parameters": parameters,
			},
		})
	}
	return output, true, nil
}

func lowerAnthropicToolChoice(raw any, exists bool) (any, bool, error) {
	if !exists {
		return nil, false, nil
	}
	choice, ok := raw.(map[string]any)
	if !ok {
		return nil, false, ErrEndpointBodyInvalid
	}
	switch choice["type"] {
	case "auto":
		return "auto", true, nil
	case "any":
		return "required", true, nil
	case "none":
		return "none", true, nil
	case "tool":
		name, ok := nonEmptyString(choice["name"])
		if !ok {
			return nil, false, ErrEndpointBodyInvalid
		}
		return map[string]any{
			"type": "function", "function": map[string]any{"name": name},
		}, true, nil
	default:
		return nil, false, ErrEndpointBodyInvalid
	}
}
