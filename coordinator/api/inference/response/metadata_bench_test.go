package response

import (
	"strings"
	"testing"
)

func BenchmarkStripProviderChatMetadata(b *testing.B) {
	chatContentChunk := func(text string) string {
		return `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1700000000,"model":"burst-model","choices":[{"index":0,"delta":{"content":"` + text + `"},"finish_reason":null}]}` + "\n\n"
	}
	for _, tc := range []struct {
		name  string
		chunk string
	}{
		{"content", chatContentChunk("Hello world")},
		{"large_content", chatContentChunk(strings.Repeat("ordinary content ", 4096))},
		{"tool_arguments", tcDelta(0, "call_1", "run", `{"message":"quoted content","count":1}`)},
		{"reserved_metadata", `data: {"choices":[],"Metadata":{"provider_id":"forged"}}`},
	} {
		b.Run(tc.name, func(b *testing.B) {
			b.ReportAllocs()
			for range b.N {
				_ = stripProviderChatMetadata(tc.chunk)
			}
		})
	}
}
