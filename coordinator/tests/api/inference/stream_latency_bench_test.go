package inference_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

// BenchmarkCoordinatorStream measures a complete 200-delta relay, including
// request-outcome observation and (optionally) sender transport encryption.
// The provider has already generated the burst: this isolates coordinator CPU
// and allocations, not model generation or network latency.
func BenchmarkCoordinatorStream(b *testing.B) {
	for _, sealed := range []bool{false, true} {
		transport := "plain"
		if sealed {
			transport = "sealed"
		}
		for _, variant := range relayVariants {
			b.Run(transport+"/"+variant, func(b *testing.B) {
				s := newRelayBenchServer()
				b.Cleanup(s.Close)
				endpoint := "/v1/" + variant
				if variant == "chat" {
					endpoint = "/v1/chat/completions"
				}
				var envelope []byte
				handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					pr := newPrefilledBurstRequest(200, variant)
					rp := s.observation.NewRequestProfile(r, pr.Model, pr.Model, true)
					pr.Profile = rp.NewAttempt(pr.RequestID, 0, "")
					defer pr.Profile.CompleteHandler()
					defer pr.Profile.CompleteTerminal()
					s.NewRelay().Stream(w, r, pr, nil, nil)
				})
				if sealed {
					key, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
					if err != nil {
						b.Fatal(err)
					}
					s.SetCoordinatorKey(key)
					envelope, _, _ = sealRequest(b, []byte(`{"stream":true}`), key.PublicKey, key.KID)
					handler = s.SealedTransport(handler)
				}
				handler = s.observation.ObserveRequestOutcome(handler)
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					request := httptest.NewRequest(http.MethodPost, endpoint, bytes.NewReader(envelope))
					if sealed {
						request.Header.Set("Content-Type", SealedContentType)
					}
					handler(newCountingResponseWriter(), request)
				}
			})
		}
	}
}
