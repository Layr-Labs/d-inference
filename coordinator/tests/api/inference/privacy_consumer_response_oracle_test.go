package inference_test

import (
	"encoding/json"
	"fmt"
	"strings"
)

// privacyConsumerResponseError and its two field readers are this package's
// copies of the consumer-response oracle in
// contracts/provider_body_privacy_test.go, which also holds its controls
// (TestPrivacyConsumerResponseOracle); the composed cache-planning cases here
// use it.
//
// These assertions qualify the synthetic transport fixture, not model quality
// or hosted OpenRouter behavior. HTTP 200 alone is insufficient.
func privacyConsumerResponseError(path string, stream bool, body []byte) error {
	if !stream {
		var response map[string]any
		if err := json.Unmarshal(body, &response); err != nil {
			return err
		}
		if response["error"] != nil {
			return fmt.Errorf("consumer response contains an error")
		}
		switch path {
		case "/v1/chat/completions", "/v1/completions":
			if privacyChoiceText(response, path == "/v1/chat/completions", false) {
				return nil
			}
		case "/v1/responses":
			if response["status"] == "completed" {
				items, _ := response["output"].([]any)
				for _, raw := range items {
					item, _ := raw.(map[string]any)
					if privacyContentText(item) {
						return nil
					}
				}
			}
		case "/v1/messages":
			if response["type"] == "message" && response["stop_reason"] != nil && privacyContentText(response) {
				return nil
			}
		}
		return fmt.Errorf("consumer response lacks completed endpoint text")
	}
	text := strings.ReplaceAll(string(body), "\r\n", "\n")
	terminal, semantic := 0, false
	lastType := ""
	for _, payload := range parseSSEDataLines(text) {
		var event map[string]any
		if err := json.Unmarshal([]byte(payload), &event); err != nil {
			return fmt.Errorf("invalid SSE JSON: %w", err)
		}
		typ, _ := event["type"].(string)
		lastType = typ
		if event["error"] != nil || typ == "error" || typ == "response.failed" || typ == "response.incomplete" {
			return fmt.Errorf("consumer stream contains an error/incomplete event")
		}
		switch path {
		case "/v1/chat/completions", "/v1/completions":
			semantic = semantic || privacyChoiceText(event, path == "/v1/chat/completions", true)
		case "/v1/responses":
			if typ == "response.output_text.delta" {
				delta, _ := event["delta"].(string)
				semantic = semantic || delta != ""
			}
			if typ == "response.completed" {
				response, _ := event["response"].(map[string]any)
				if response["status"] != "completed" {
					return fmt.Errorf("Responses terminal is not completed")
				}
				terminal++
			}
		case "/v1/messages":
			if typ == "content_block_delta" {
				delta, _ := event["delta"].(map[string]any)
				value, _ := delta["text"].(string)
				semantic = semantic || value != ""
			}
			if typ == "message_stop" {
				terminal++
			}
		}
	}
	if path == "/v1/chat/completions" || path == "/v1/completions" {
		terminal = strings.Count(text, "data: [DONE]")
		if !strings.HasSuffix(strings.TrimSpace(text), "data: [DONE]") {
			return fmt.Errorf("missing final DONE")
		}
	} else if (path == "/v1/responses" && lastType != "response.completed") ||
		(path == "/v1/messages" && lastType != "message_stop") {
		return fmt.Errorf("endpoint terminal is not last")
	}
	if terminal != 1 || !semantic {
		return fmt.Errorf("consumer stream terminal=%d semantic=%t", terminal, semantic)
	}
	return nil
}

func privacyChoiceText(response map[string]any, chat, stream bool) bool {
	choices, _ := response["choices"].([]any)
	for _, raw := range choices {
		choice, _ := raw.(map[string]any)
		if !stream {
			finish, _ := choice["finish_reason"].(string)
			if finish == "" {
				continue
			}
		}
		value, _ := choice["text"].(string)
		if chat {
			field := "message"
			if stream {
				field = "delta"
			}
			message, _ := choice[field].(map[string]any)
			value, _ = message["content"].(string)
		}
		if value != "" {
			return true
		}
	}
	return false
}

func privacyContentText(response map[string]any) bool {
	items, _ := response["content"].([]any)
	for _, raw := range items {
		item, _ := raw.(map[string]any)
		text, _ := item["text"].(string)
		if text != "" {
			return true
		}
	}
	return false
}
