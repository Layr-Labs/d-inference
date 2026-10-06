package response_test

import (
	"fmt"
	"testing"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
)

// Measures complete reconstruction, including JSON decoding, for a tool that
// streams one argument over many deltas. The output grows with fragment count;
// the accumulator must not copy every preceding fragment on each append.
func BenchmarkExtractMessageToolArguments(b *testing.B) {
	for _, fragments := range []int{64, 512, 2048} {
		b.Run(fmt.Sprintf("fragments_%d", fragments), func(b *testing.B) {
			const fragment = "0123456789abcdef0123456789abcdef"
			chunks := make([]string, 0, fragments+2)
			chunks = append(chunks, publicTcDelta(0, "call_1", "run", `{"text":"`))
			for range fragments {
				chunks = append(chunks, publicTcDelta(0, "", "", fragment))
			}
			chunks = append(chunks, publicTcDelta(0, "", "", `"}`))
			b.ReportAllocs()
			b.SetBytes(int64(len(fragment) * fragments))
			b.ResetTimer()
			for range b.N {
				msg := inresp.ExtractMessage(chunks)
				if len(msg.ToolCalls) != 1 {
					b.Fatal("tool call was lost")
				}
			}
		})
	}
}
