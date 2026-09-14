package dispatch

import (
	"encoding/json"
	"fmt"
)

// roleOnlyChunkSSE is the OpenAI boilerplate role-only delta chunk every
// backend emits before any content. Per the WS-C contract it must NOT commit
// the dispatch.
func roleOnlyChunkSSE(model string) string {
	return fmt.Sprintf(`data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":%q,"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`+"\n\n", model)
}

func contentChunkSSE(model, text string) string {
	data, _ := json.Marshal(text)
	return fmt.Sprintf(`data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":%q,"choices":[{"index":0,"delta":{"content":%s},"finish_reason":null}]}`+"\n\n", model, data)
}
