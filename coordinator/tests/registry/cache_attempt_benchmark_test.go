package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheattempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type cacheDequeueGate struct{ active bool }

func (g *cacheDequeueGate) Active() bool { return g.active }

func BenchmarkCacheAttemptDequeue(b *testing.B) {
	for _, kind := range []string{"ordinary", "prepared", "revoked"} {
		b.Run(kind, func(b *testing.B) {
			var owner *cacheattempt.Owner
			gate := &cacheDequeueGate{active: true}
			if kind != "ordinary" {
				owner = cacheattempt.New(cacheattempt.Metadata{Nonce: "nonce", Scope: "scope"}, gate, nil)
			}
			if kind == "revoked" {
				gate.active = false
			}
			var frame protocol.InferenceRequestMessage
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				owner.ApplyTo(&frame)
			}
			b.StopTimer()
			if (frame.CacheReceiptNonce != "") != (kind == "prepared") {
				b.Fatal("wrong dispatch state")
			}
		})
	}
}
