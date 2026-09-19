package registry

import (
	"fmt"
	"testing"
)

// BenchmarkAccountAffinityPolicy isolates per-request policy overhead after
// the scheduler has already built its request-local candidate pool. Identity
// snapshot construction belongs to the scheduler benchmark, not this helper.
func BenchmarkAccountAffinityPolicy(b *testing.B) {
	for _, size := range []int{32, 350, 1000} {
		for _, mode := range []string{AccountAffinityOff, AccountAffinityShadow, AccountAffinityOn} {
			b.Run(fmt.Sprintf("%s/%d", mode, size), func(b *testing.B) {
				pool := make([]*routingCandidate, size)
				for i := range pool {
					pool[i] = newAccountAffinityPolicyCandidate(fmt.Sprintf("serial:%d", i), 1000+float64(i%100))
				}
				pr := &PendingRequest{ConsumerKey: "benchmark-account", Model: "model-a", MinDecodeTPS: 15}
				cfg := AccountAffinityConfig{Mode: mode, MaxTTFTPenaltyMs: 250}
				b.ReportAllocs()
				b.ResetTimer()
				for b.Loop() {
					evaluateAccountAffinity(pool, pr, cfg)
				}
			})
		}
	}
}
