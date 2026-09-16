package api

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

func TestDispatchRetryAfterPreservesBoundedProviderForecast(t *testing.T) {
	for _, tc := range []struct {
		name string
		ms   int64
		want string
	}{
		{"minimum", 1, "2"},
		{"round up", 2001, "3"},
		{"upper bound", 30001, "30"},
		{"rounding overflow", math.MaxInt64 - 998, "30"},
		{"maximum wire value", math.MaxInt64, "30"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg, _, ts := setupFailoverServer(t)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			const model = "retry-hint-model"
			provider := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
				Name: "retry-hint-provider", Version: "0.9.0", DecodeTPS: 100,
				Models: []failoverModelSpec{{ID: model}},
				Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
					data, err := json.Marshal(protocol.InferenceErrorMessage{
						Type: protocol.TypeInferenceError, RequestID: req.RequestID,
						StatusCode: http.StatusServiceUnavailable, FailureCode: protocol.FailureCodeCapacity,
						ErrorReason: attempt.ErrorReasonRequestExceedsContext, FeasibleAfterMS: tc.ms,
					})
					if err != nil {
						t.Error(err)
						return
					}
					if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
						t.Error(err)
					}
				},
			})
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
				strings.NewReader(buildChatBody(t, model, false, nil)))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("Authorization", "Bearer test-key")
			req.Header.Set("Content-Type", "application/json")
			response, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			if response.StatusCode != http.StatusTooManyRequests || provider.dispatchCount() != 1 {
				t.Fatalf("status=%d, dispatches=%d; expected one provider refusal and 429", response.StatusCode, provider.dispatchCount())
			}
			if got := response.Header.Get("Retry-After"); got != tc.want {
				t.Fatalf("Retry-After=%q for feasible_after_ms=%d, want %q", got, tc.ms, tc.want)
			}
		})
	}
}
