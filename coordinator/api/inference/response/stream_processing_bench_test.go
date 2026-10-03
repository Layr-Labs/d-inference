package response

import (
	"strings"
	"testing"
)

func BenchmarkStripProviderChatMetadata(b *testing.B) {
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
