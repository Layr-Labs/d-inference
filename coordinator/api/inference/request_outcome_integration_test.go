package inference

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func awaitRequestOutcomes(t *testing.T, s store.RequestOutcomeStore, n int) []store.RequestOutcomeRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		rows, err := s.RequestOutcomes(context.Background(), time.Time{}, time.Now().Add(time.Second), 100)
		if err != nil {
			t.Fatal(err)
		}
		done := len(rows) == n
		for _, r := range rows {
			done = done && r.FinalizedAt != nil
		}
		if done {
			return rows
		}
		if time.Now().After(deadline) {
			t.Fatalf("request ledger did not settle: %+v", rows)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func nativeOutcomeBody(endpoint, model string, stream bool) string {
	switch endpoint {
	case "/v1/responses":
		return fmt.Sprintf(`{"model":%q,"input":"hello","stream":%t,"max_output_tokens":16}`, model, stream)
	case "/v1/completions":
		return fmt.Sprintf(`{"model":%q,"prompt":"hello","stream":%t,"max_tokens":16}`, model, stream)
	default:
		return fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hello"}],"stream":%t,"max_tokens":16}`, model, stream)
	}
}

var outcomeEndpoints = []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"}

func TestRequestOutcomesProviderErrorAfterContentAllEndpoints(t *testing.T) {
	for _, endpoint := range outcomeEndpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/%t", endpoint, stream), func(t *testing.T) {
				t.Setenv(envProfiler, "off")
				reg, st, srv, ts := setupTTFTFailoverServer(t)
				t.Cleanup(srv.Close)
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				const model = "outcome-error-model"
				startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{Name: "error-provider", Version: "0.8.10", DecodeTPS: 200, Models: []failoverModelSpec{{ID: model}}, Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
					fp.sendContentChunk(ctx, req, model, "some content")
					time.Sleep(30 * time.Millisecond)
					fp.sendInferenceError(ctx, req, "provider failed", 500)
				}})
				req, _ := http.NewRequestWithContext(ctx, "POST", ts.URL+endpoint, strings.NewReader(nativeOutcomeBody(endpoint, model, stream)))
				req.Header.Set("Authorization", "Bearer test-key")
				req.Header.Set("Content-Type", "application/json")
				res, err := http.DefaultClient.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				io.Copy(io.Discard, res.Body)
				res.Body.Close()
				r := awaitRequestOutcomes(t, st, 1)[0]
				want := "rejected"
				if stream {
					want = "interrupted_response"
				}
				if r.Termination != want || r.ProviderOutcome != "error" || !r.ProviderContentObserved || r.ContentWriteCompleted != stream || !r.EgressCompleted || r.ResponseTerminal != "error" {
					t.Fatalf("error evidence %+v", r)
				}
			})
		}
	}
}
