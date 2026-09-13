package api

import (
	"fmt"
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

// Measures complete reconstruction, including JSON decoding, for a tool that
// streams one argument over many deltas. The output grows with fragment count;
// the accumulator must not copy every preceding fragment on each append.
func BenchmarkExtractMessageToolArguments(b *testing.B) {
	for _, fragments := range []int{64, 512, 2048} {
		b.Run(fmt.Sprintf("fragments_%d", fragments), func(b *testing.B) {
			const fragment = "0123456789abcdef0123456789abcdef"
			chunks := make([]string, 0, fragments+2)
			chunks = append(chunks, tcDelta(0, "call_1", "run", `{"text":"`))
			for range fragments {
				chunks = append(chunks, tcDelta(0, "", "", fragment))
			}
			chunks = append(chunks, tcDelta(0, "", "", `"}`))
			b.ReportAllocs()
			b.SetBytes(int64(len(fragment) * fragments))
			b.ResetTimer()
			for range b.N {
				msg := extractMessage(chunks)
				if len(msg.ToolCalls) != 1 {
					b.Fatal("tool call was lost")
				}
			}
		})
	}
}
