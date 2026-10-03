package api

import (
	"strings"
	"testing"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
)

func TestSanitizeNestedResponsesStreamCacheDetails(t *testing.T) {
	chunk := "event: response.completed\n" +
		"id: response-7\n" +
		": retain this comment\n" +
		`data: {"type":"response.completed","response":{"usage":{` + "\n" +
		`data: "input_tokens_details":{"cached\u005ftokens":99,"audio_tokens":7}}}}` + "\n\n"
	got := inresp.SanitizeStreamCacheDetails(chunk)
	if strings.Contains(got, `"cached_tokens"`) || strings.Contains(got, `cached\u005ftokens`) || strings.Contains(got, "99") {
		t.Fatalf("nested Responses cached_tokens survived: %s", got)
	}
	if !strings.Contains(got, `"audio_tokens":7`) || !strings.Contains(got, "event: response.completed") ||
		!strings.Contains(got, "id: response-7") || !strings.Contains(got, ": retain this comment") || strings.Count(got, "data:") != 1 {
		t.Fatalf("nested Responses sanitization removed unrelated content: %s", got)
	}
}

func TestSanitizeSplitMultilineChatStreamCacheDetails(t *testing.T) {
	for _, tc := range []struct {
		name    string
		choices string
	}{
		{name: "content", choices: `[{"delta":{"content":"hi"},"finish_reason":null}]`},
		{name: "finish", choices: `[{"delta":{},"finish_reason":"stop"}]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			chunk := "event: message\n" +
				"id: chat-9\n" +
				": keepalive\n" +
				`data: {"object":"chat.completion.chunk","choices":` + tc.choices + `,` + "\n" +
				`data: "usage":{"prompt_tokens_details":{"cached\u005ftokens":123,"audio_tokens":6}}}` + "\n\n"
			got := inresp.SanitizeStreamCacheDetails(chunk)
			if strings.Contains(got, "123") || strings.Contains(got, `cached\u005ftokens`) || strings.Contains(got, `"cached_tokens"`) {
				t.Fatalf("split %s frame retained cached_tokens: %s", tc.name, got)
			}
			for _, preserved := range []string{`"audio_tokens":6`, "event: message", "id: chat-9", ": keepalive"} {
				if !strings.Contains(got, preserved) {
					t.Fatalf("split %s frame lost %q: %s", tc.name, preserved, got)
				}
			}
			if strings.Count(got, "data:") != 1 || !strings.HasSuffix(got, "\n\n") {
				t.Fatalf("split %s frame was not re-emitted as one data line/event: %q", tc.name, got)
			}
		})
	}
}
