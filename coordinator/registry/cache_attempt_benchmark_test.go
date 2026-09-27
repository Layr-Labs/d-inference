package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func BenchmarkCacheAttemptDequeue(b *testing.B) {
	for _, kind := range []string{"ordinary", "prepared", "revoked"} {
		b.Run(kind, func(b *testing.B) {
			snapshot := CacheAttemptSnapshot{}
			if kind != "ordinary" {
				snapshot.owner = &cacheAttemptOwner{generation: &cacheRoutingGeneration{}, nonce: "nonce", scope: "scope"}
			}
			if kind == "revoked" {
				snapshot.owner.generation.revoked.Store(true)
			}
			var frame protocol.InferenceRequestMessage
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				snapshot.ApplyTo(&frame)
			}
			b.StopTimer()
			if (frame.CacheReceiptNonce != "") != (kind == "prepared") {
				b.Fatal("wrong dispatch state")
			}
		})
	}
}
