package registry

import (
	"bytes"
	"context"
	"fmt"
	"testing"
)

// BenchmarkProviderWriterFrame measures the per-message cost of the data-lane
// writer over a live loopback WebSocket pair at sizes below and above the
// fragment threshold. Fragmentation engages only above
// providerWriteFragmentBytes, so the sub-threshold sizes (512 B, 8 KiB,
// 60 KiB) are the no-regression guard for the fragmented writer and the
// 128 KiB size shows the fragmented path itself (three frames: two 64 KiB
// fragments plus nhooyr's empty FIN continuation).
func BenchmarkProviderWriterFrame(b *testing.B) {
	for _, size := range []int{512, 8 << 10, 60 << 10, 128 << 10} {
		b.Run(fmt.Sprintf("bytes=%d", size), func(b *testing.B) {
			serverConn, clientConn := testWebSocketPair(b)
			clientConn.SetReadLimit(-1)
			go func() {
				for {
					if _, _, err := clientConn.Read(context.Background()); err != nil {
						return
					}
				}
			}()
			w := newProviderWriter(serverConn)
			b.Cleanup(w.closeNow)
			payload := bytes.Repeat([]byte("a"), size)
			b.SetBytes(int64(size))
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if err := w.write(context.Background(), payload); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
