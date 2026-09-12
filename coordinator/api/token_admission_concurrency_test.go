package api

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestConcurrentTokenAdmissionRespectsAccountBurst(t *testing.T) {
	for _, mode := range []string{"account", "key", "both", "separate keys"} {
		t.Run(mode, func(t *testing.T) {
			for attempt := 0; attempt < 100; attempt++ {
				s := &Server{}
				if mode != "key" {
					s.consumerTokenLimiter = ratelimit.NewTokenLimiter(0.000001, 1, 0.000001, 1)
				}
				if mode != "account" {
					s.keyTokenLimiter = ratelimit.NewKeyTokenLimiter()
				}
				start := make(chan struct{})
				var wg sync.WaitGroup
				var admitted atomic.Int32
				for i := 0; i < 16; i++ {
					wg.Add(1)
					go func(index int) {
						defer wg.Done()
						var req *http.Request
						if mode == "account" {
							req = tokenReq("same-account", "")
						} else {
							keyID := "shared-key"
							if mode == "separate keys" {
								keyID = fmt.Sprintf("key-%d", index)
							}
							limit := int64(1)
							req = tokenReqWithKey("same-account", "", &store.APIKey{ID: keyID, ITPMLimit: &limit, OTPMLimit: &limit})
						}
						<-start
						if s.applyTokenRateLimit(httptest.NewRecorder(), req, 1, 1) {
							admitted.Add(1)
						}
					}(i)
				}
				close(start)
				wg.Wait()
				if admitted.Load() != 1 {
					t.Fatalf("round %d admitted %d requests from a one-token burst", attempt, admitted.Load())
				}
			}
		})
	}
}
