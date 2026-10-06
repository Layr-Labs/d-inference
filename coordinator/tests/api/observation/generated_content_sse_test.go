package observation_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/observation"
)

func TestGeneratedContentEvidenceExcludesPreambleAndTerminals(t *testing.T) {
	roleOnly := `data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}` + "\n\n"
	for _, s := range []string{`data: [DONE]`, `data: {broken`, roleOnly, `data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`, `data: {"type":"response.created","response":{}}`, `data: {"error":{"message":"secret"}}`, `data: {"choices":[],"usage":{"completion_tokens":0}}`} {
		if production.GeneratedContentSSE([]byte(s)) {
			t.Errorf("false content: %s", s)
		}
	}
	content := `data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":"m","choices":[{"index":0,"delta":{"content":"a"},"finish_reason":null}]}` + "\n\n"
	for _, s := range []string{content, `data: {"type":"response.output_text.delta","delta":"a"}`, `data: {"type":"content_block_delta","delta":{"text":"a"}}`} {
		if !production.GeneratedContentSSE([]byte(s)) {
			t.Errorf("missed content %s", s)
		}
	}
}
