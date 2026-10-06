package inference_test

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
