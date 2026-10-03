package response

const burstTestModel = "burst-model"

// chatContentChunk is one chat.completion.chunk content delta, framed the way
// the Swift provider frames it (SSE line + blank line).
func chatContentChunk(text string) string {
	return `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1700000000,"model":"` +
		burstTestModel + `","choices":[{"index":0,"delta":{"content":"` + text + `"},"finish_reason":null}]}` + "\n\n"
}
