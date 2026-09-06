package api

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func BenchmarkProviderInferenceFrameBuild(b *testing.B) {
	for _, prepared := range []bool{false, true} {
		name := "ordinary"
		if prepared {
			name = "cache_prepared"
		}
		b.Run(name, func(b *testing.B) {
			var pending *registry.PendingRequest
			if prepared {
				_, _, pending = preparedCacheAttemptForTest(b)
			}
			builder := providerInferenceFrameBuilder("request", "ephemeral", "ciphertext", pending)
			now := time.Now()
			sample, err := builder(now)
			if err != nil {
				b.Fatal(err)
			}
			var frame protocol.InferenceRequestMessage
			if err := json.Unmarshal(sample, &frame); err != nil {
				b.Fatal(err)
			}
			if (frame.CacheReceiptNonce != "") != prepared {
				b.Fatal("fixture did not exercise requested cache path")
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := builder(now); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
