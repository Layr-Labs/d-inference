package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

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

func postPrivacyAndCapture(t *testing.T, ctx context.Context, ts *httptest.Server, fp *failoverProvider, path, apiKey, body string, inspect ...func([]byte, http.Header)) []byte {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("incomplete consumer read: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("consumer status=%d", resp.StatusCode)
	}
	request, err := inreq.DecodeInferenceJSONObject([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	stream, _ := request["stream"].(bool)
	if err := privacyConsumerResponseError(path, stream, responseBody); err != nil {
		t.Fatal(err)
	}
	for _, check := range inspect {
		check(responseBody, resp.Header)
	}
	select {
	case got := <-fp.bodies:
		if got == nil {
			t.Fatal("provider could not decrypt request")
		}
		return got
	case <-time.After(5 * time.Second):
		t.Fatal("provider did not receive request")
	}
	return nil
}

func TestPrivacyConsumerResponseOracle(t *testing.T) {
	for _, fixture := range []struct {
		name, path, body string
		stream, valid    bool
	}{
		{"empty 200", "/v1/chat/completions", `{}`, false, false},
		{"wrong endpoint", "/v1/messages", `{"choices":[{"message":{"content":"ok"}}]}`, false, false},
		{"content without terminal", "/v1/chat/completions", "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n", true, false},
		{"terminal without content", "/v1/chat/completions", "data: [DONE]\n\n", true, false},
		{"duplicate terminal", "/v1/chat/completions", "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\ndata: [DONE]\n\n", true, false},
		{"chat without finish", "/v1/chat/completions", `{"choices":[{"message":{"content":"ok"}}]}`, false, false},
		{"valid chat", "/v1/chat/completions", `{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}`, false, true},
		{"valid messages", "/v1/messages", `{"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}`, false, true},
		{"valid responses", "/v1/responses", `{"status":"completed","output":[{"content":[{"type":"output_text","text":"ok"}]}]}`, false, true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			if valid := privacyConsumerResponseError(fixture.path, fixture.stream, []byte(fixture.body)) == nil; valid != fixture.valid {
				t.Fatalf("response oracle accepted=%t want=%t", valid, fixture.valid)
			}
		})
	}
}

func assertCallerIdentityAbsent(t *testing.T, body []byte) {
	t.Helper()
	parsed, err := inreq.DecodeInferenceJSONObject(body)
	if err != nil {
		t.Fatal(err)
	}
	// Protocol-0 may append its coordinator-authored cache-bust key after
	// sanitization. Exact body oracles distinguish it from caller input.
	if parsed["prompt_cache_key"] == "synthetic-caller-key" {
		t.Error("caller cache key forwarded")
	}
	for _, field := range []string{"user", "metadata", "safety_identifier"} {
		if _, exists := parsed[field]; exists {
			t.Errorf("provider-bound request retains top-level caller %q", field)
		}
	}
}
