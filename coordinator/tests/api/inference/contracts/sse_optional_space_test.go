package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// The provider's SSE contract makes the space after data: optional. Exercise
// equivalent frames over the encrypted provider WebSocket and real HTTP router,
// including response translation and non-streaming reconstruction.
func TestProviderSSEOptionalSpaceHTTP(t *testing.T) {
	for _, endpoint := range []struct{ name, path, fields string }{
		{"chat", "/v1/chat/completions", `"messages":[{"role":"user","content":"hi"}],"max_tokens":1000,"stream_options":{"include_usage":true}`},
		{"completions", "/v1/completions", `"prompt":"hi","max_tokens":1000`},
		{"messages", "/v1/messages", `"messages":[{"role":"user","content":"hi"}],"max_tokens":1000`},
		{"responses", "/v1/responses", `"input":"hi","max_output_tokens":1000`},
	} {
		for _, streaming := range []bool{false, true} {
			for _, spaced := range []bool{true, false} {
				t.Run(fmt.Sprintf("%s/stream=%t/space=%t", endpoint.name, streaming, spaced), func(t *testing.T) {
					_, reg, _, ts := setupTestServer(t)
					defer ts.Close()
					ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
					defer cancel()
					p := startBurstProvider(t, ctx, ts, reg, func(ctx context.Context, p *burstProvider, req protocol.InferenceRequestMessage) {
						for _, frame := range []string{chatContentChunk("Hello "), chatContentChunk("world"), chatFinishChunk("stop"), chatUsageChunk(10, 2), "data: [DONE]\n\n"} {
							if !spaced {
								frame = strings.Replace(frame, "data: ", "data:", 1)
							}
							p.writeChunk(t, ctx, req, frame)
						}
						p.writeComplete(t, ctx, req, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 2})
					})
					defer p.conn.Close(websocket.StatusNormalClosure, "")
					body := fmt.Sprintf(`{"model":%q,%s,"stream":%t}`, burstTestModel, endpoint.fields, streaming)
					status, headers, raw := streamRequest(t, ctx, ts, endpoint.path, body)
					if status != http.StatusOK {
						t.Fatalf("status=%d body=%s", status, raw)
					}
					if streaming && headers.Get("Content-Type") != "text/event-stream" {
						t.Fatalf("content-type=%q", headers.Get("Content-Type"))
					}
					got := optionalSpaceHTTPText(t, endpoint.name, streaming, raw)
					if got != "Hello world" {
						t.Errorf("response lost provider text: got %q, want %q; body=%s", got, "Hello world", raw)
					}
				})
			}
		}
	}
}

type optionalSpaceHTTPResponse struct {
	Type    string          `json:"type"`
	Delta   json.RawMessage `json:"delta"`
	Error   json.RawMessage `json:"error"`
	Choices []struct {
		Text         string  `json:"text"`
		FinishReason *string `json:"finish_reason"`
		Delta        struct {
			Content string `json:"content"`
		} `json:"delta"`
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	Content []struct {
		Text string `json:"text"`
	} `json:"content"`
	Output []struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
	} `json:"output"`
}

func optionalSpaceHTTPText(t *testing.T, endpoint string, streaming bool, raw []byte) string {
	t.Helper()
	var text strings.Builder
	decode := func(payload []byte) optionalSpaceHTTPResponse {
		t.Helper()
		var result optionalSpaceHTTPResponse
		if err := json.Unmarshal(payload, &result); err != nil {
			t.Fatalf("invalid HTTP response: %v; payload=%s", err, payload)
		}
		if len(result.Error) > 0 && string(result.Error) != "null" {
			t.Fatalf("unexpected error: %s", payload)
		}
		return result
	}
	if !streaming {
		response := decode(raw)
		for _, choice := range response.Choices {
			text.WriteString(choice.Text)
			text.WriteString(choice.Message.Content)
		}
		for _, block := range response.Content {
			text.WriteString(block.Text)
		}
		for _, item := range response.Output {
			for _, block := range item.Content {
				text.WriteString(block.Text)
			}
		}
		return text.String()
	}
	terminals, finishes := 0, 0
	for _, line := range strings.Split(string(raw), "\n") {
		payload, data := strings.CutPrefix(line, "data:")
		if !data {
			continue
		}
		payload = strings.TrimSpace(payload)
		if payload == "[DONE]" {
			terminals++
			continue
		}
		event := decode([]byte(payload))
		for _, choice := range event.Choices {
			text.WriteString(choice.Text)
			text.WriteString(choice.Delta.Content)
			if choice.FinishReason != nil && *choice.FinishReason != "" {
				finishes++
			}
		}
		switch event.Type {
		case "response.output_text.delta":
			var delta string
			if err := json.Unmarshal(event.Delta, &delta); err != nil {
				t.Fatal(err)
			}
			text.WriteString(delta)
		case "content_block_delta":
			var delta struct {
				Text string `json:"text"`
			}
			if err := json.Unmarshal(event.Delta, &delta); err != nil {
				t.Fatal(err)
			}
			text.WriteString(delta.Text)
		case "response.completed", "message_stop":
			terminals++
		}
	}
	if terminals != 1 {
		t.Errorf("terminal count=%d, want1; body=%s", terminals, raw)
	}
	if (endpoint == "chat" || endpoint == "completions") && finishes != 1 {
		t.Errorf("finish count=%d, want1; body=%s", finishes, raw)
	}
	return text.String()
}
