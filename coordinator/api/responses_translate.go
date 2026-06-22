package api

// Translation of OpenAI Responses-API requests (`input`, `tools`,
// `tool_choice`, `text.format`) into the chat-completions shape the provider
// backend serves. Response-direction building lives alongside the streaming
// helpers; this file is the request-direction lowering only.

import (
	"encoding/json"
	"fmt"
	"strings"
)

func responsesContentText(content any) string {
	switch c := content.(type) {
	case nil:
		return ""
	case string:
		return c
	case []any:
		parts := make([]string, 0, len(c))
		for _, part := range c {
			switch p := part.(type) {
			case string:
				if p != "" {
					parts = append(parts, p)
				}
			case map[string]any:
				if text, _ := p["text"].(string); text != "" {
					parts = append(parts, text)
					continue
				}
				if p["type"] == "input_image" || p["type"] == "input_file" {
					// Text models cannot consume binary Responses parts yet.
					// Preserve the turn shape without leaking URLs or blobs.
					parts = append(parts, fmt.Sprintf("[%s omitted]", p["type"]))
				}
			}
		}
		return strings.Join(parts, "\n")
	default:
		b, err := json.Marshal(c)
		if err != nil {
			return fmt.Sprint(c)
		}
		return string(b)
	}
}

func responsesInputToChatMessages(input any) ([]map[string]any, error) {
	switch v := input.(type) {
	case string:
		return []map[string]any{{"role": "user", "content": v}}, nil
	case []any:
		messages := make([]map[string]any, 0, len(v))
		for _, raw := range v {
			item, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			if typ, _ := item["type"].(string); typ != "" {
				switch typ {
				case "message":
					role, _ := item["role"].(string)
					if role == "" {
						role = "user"
					}
					if role == "developer" {
						role = "system"
					}
					messages = append(messages, map[string]any{
						"role":    role,
						"content": responsesContentText(item["content"]),
					})
				case "function_call":
					callID, _ := item["call_id"].(string)
					if callID == "" {
						callID, _ = item["id"].(string)
					}
					name, _ := item["name"].(string)
					args, _ := item["arguments"].(string)
					messages = append(messages, map[string]any{
						"role":    "assistant",
						"content": "",
						"tool_calls": []map[string]any{{
							"id":   callID,
							"type": "function",
							"function": map[string]any{
								"name":      name,
								"arguments": args,
							},
						}},
					})
				case "function_call_output":
					callID, _ := item["call_id"].(string)
					messages = append(messages, map[string]any{
						"role":         "tool",
						"tool_call_id": callID,
						"content":      responsesContentText(item["output"]),
					})
				case "reasoning":
					// Reasoning items are model-side metadata, not prompt text.
					continue
				default:
					return nil, fmt.Errorf("unsupported Responses input item type %q", typ)
				}
				continue
			}

			role, _ := item["role"].(string)
			if role == "" {
				continue
			}
			if role == "developer" {
				role = "system"
			}
			messages = append(messages, map[string]any{
				"role":    role,
				"content": responsesContentText(item["content"]),
			})
		}
		if len(messages) == 0 {
			return nil, fmt.Errorf("Responses input did not contain any chat-compatible messages")
		}
		return messages, nil
	default:
		return nil, fmt.Errorf("Responses input must be a string or array")
	}
}

func responsesToolsToChatTools(raw any) ([]any, error) {
	tools, ok := raw.([]any)
	if !ok || len(tools) == 0 {
		return nil, nil
	}
	out := make([]any, 0, len(tools))
	for _, rawTool := range tools {
		tool, ok := rawTool.(map[string]any)
		if !ok {
			continue
		}
		typ, _ := tool["type"].(string)
		if typ == "" || typ == "function" {
			name, _ := tool["name"].(string)
			if name == "" {
				if fn, _ := tool["function"].(map[string]any); fn != nil {
					out = append(out, tool)
					continue
				}
				return nil, fmt.Errorf("function tool is missing name")
			}
			fn := map[string]any{"name": name}
			if description, ok := tool["description"].(string); ok {
				fn["description"] = description
			}
			if parameters, ok := tool["parameters"]; ok {
				fn["parameters"] = parameters
			}
			out = append(out, map[string]any{
				"type":     "function",
				"function": fn,
			})
			continue
		}
		return nil, fmt.Errorf("unsupported Responses tool type %q", typ)
	}
	return out, nil
}

func responsesToolChoiceToChat(raw any) (any, error) {
	choice, ok := raw.(map[string]any)
	if !ok {
		return raw, nil
	}
	typ, _ := choice["type"].(string)
	if typ == "function" {
		name, _ := choice["name"].(string)
		if name == "" {
			return nil, fmt.Errorf("function tool_choice is missing name")
		}
		return map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": name,
			},
		}, nil
	}
	return raw, nil
}

func responsesTextFormatToChatResponseFormat(raw any) any {
	text, ok := raw.(map[string]any)
	if !ok {
		return nil
	}
	format, ok := text["format"].(map[string]any)
	if !ok {
		return nil
	}
	switch format["type"] {
	case "json_object":
		return map[string]any{"type": "json_object"}
	case "json_schema":
		return map[string]any{
			"type":        "json_schema",
			"json_schema": format,
		}
	}
	return nil
}

func responsesRequestToChatCompletions(parsed map[string]any) (map[string]any, error) {
	messages, err := responsesInputToChatMessages(parsed["input"])
	if err != nil {
		return nil, err
	}

	out := copyJSONMap(parsed)
	delete(out, "input")
	delete(out, "endpoint")
	delete(out, "max_output_tokens")
	delete(out, "text")
	out["messages"] = messages
	if maxTokens := explicitMaxTokens(parsed); maxTokens > 0 {
		out["max_tokens"] = maxTokens
	}
	if tools, err := responsesToolsToChatTools(parsed["tools"]); err != nil {
		return nil, err
	} else if len(tools) > 0 {
		out["tools"] = tools
	}
	if choice, err := responsesToolChoiceToChat(parsed["tool_choice"]); err != nil {
		return nil, err
	} else if choice != nil {
		out["tool_choice"] = choice
	}
	if responseFormat := responsesTextFormatToChatResponseFormat(parsed["text"]); responseFormat != nil {
		out["response_format"] = responseFormat
	}
	return out, nil
}
