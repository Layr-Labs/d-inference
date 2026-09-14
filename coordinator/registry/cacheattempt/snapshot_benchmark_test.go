package cacheattempt

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func BenchmarkCacheAttemptDequeue(b *testing.B) {
	for _, kind := range []string{"ordinary", "prepared", "revoked"} {
		b.Run(kind, func(b *testing.B) {
			snapshot := Snapshot{}
			if kind != "ordinary" {
				snapshot.owner = &Attempt{generation: &Generation{}, metadata: Metadata{Nonce: "nonce", Scope: "scope"}}
			}
			if kind == "revoked" {
				snapshot.owner.generation.Revoke()
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
