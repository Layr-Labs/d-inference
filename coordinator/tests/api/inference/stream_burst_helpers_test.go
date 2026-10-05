package inference_test

import (
	"strings"
)

const burstTestModel = "burst-model"

// chatContentChunk is one chat.completion.chunk content delta, framed the way
// the Swift provider frames it (SSE line + blank line).
func chatContentChunk(text string) string {
	return `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1700000000,"model":"` +
		burstTestModel + `","choices":[{"index":0,"delta":{"content":"` + text + `"},"finish_reason":null}]}` + "\n\n"
}

func chatFinishChunk(reason string) string {
	return `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1700000000,"model":"` +
		burstTestModel + `","choices":[{"index":0,"delta":{},"finish_reason":"` + reason + `"}]}` + "\n\n"
}

// sseEvents splits a raw SSE body into non-empty event groups.
func sseEvents(body []byte) []string {
	var events []string
	for _, group := range strings.Split(string(body), "\n\n") {
		if strings.TrimSpace(group) == "" {
			continue
		}
		events = append(events, group)
	}
	return events
}
