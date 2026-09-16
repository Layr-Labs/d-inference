package response

import (
	"testing"
)

func TestGeneratedContentEvidenceExcludesPreambleAndTerminals(t *testing.T) {
	for _, s := range []string{`data: [DONE]`, `data: {broken`, roleOnlyChunkSSE("m"), `data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`, `data: {"type":"response.created","response":{}}`, `data: {"error":{"message":"secret"}}`, `data: {"choices":[],"usage":{"completion_tokens":0}}`} {
		if GeneratedContentSSE([]byte(s)) {
			t.Errorf("false content: %s", s)
		}
	}
	for _, s := range []string{contentChunkSSE("m", "a"), `data: {"type":"response.output_text.delta","delta":"a"}`, `data: {"type":"content_block_delta","delta":{"text":"a"}}`} {
		if !GeneratedContentSSE([]byte(s)) {
			t.Errorf("missed content %s", s)
		}
	}
}
