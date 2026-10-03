package inference_test

// Deferred-commit tests: the dispatch loop must not commit to a provider on
// boilerplate preamble chunks (role delta / Responses lifecycle events), so a
// provider that dies after its preamble — but before any real output — is
// retried invisibly instead of surfacing an in-band SSE error to a consumer
// that never received a byte.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	testkit "github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// runDeferredCommitProvider serves the fake-provider side of the failover
// test: it answers attestation challenges and, for each inference request,
// emits the boilerplate role preamble first. failing providers then send an
// inference_error (the crash-after-preamble shape from the prod incident);
// healthy ones stream real content and complete.
func runDeferredCommitProvider(ctx context.Context, t *testing.T, conn *websocket.Conn, pubKey string, fail bool, content string) {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var raw map[string]any
		if err := json.Unmarshal(data, &raw); err != nil {
			continue
		}
		msgType, _ := raw["type"].(string)
		switch msgType {
		case protocol.TypeAttestationChallenge:
			if wErr := conn.Write(ctx, websocket.MessageText, testkit.MakeValidChallengeResponse(data, pubKey)); wErr != nil {
				return
			}
		case protocol.TypeInferenceRequest:
			var inferReq protocol.InferenceRequestMessage
			if err := json.Unmarshal(data, &inferReq); err != nil {
				continue
			}
			// Boilerplate preamble — emitted before any failure-prone work.
			roleChunk := `data: {"id":"chatcmpl-dc","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`
			testkit.WriteEncryptedChunk(t, ctx, conn, inferReq, pubKey, roleChunk)
			if fail {
				errMsg := protocol.InferenceErrorMessage{
					Type:        protocol.TypeInferenceError,
					RequestID:   inferReq.RequestID,
					Error:       "provider crashed after preamble",
					StatusCode:  500,
					FailureCode: protocol.FailureCodeGenerationFailure,
				}
				errData, _ := json.Marshal(errMsg)
				if wErr := conn.Write(ctx, websocket.MessageText, errData); wErr != nil {
					return
				}
				continue
			}
			contentChunk := `data: {"id":"chatcmpl-dc","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"` + content + `"},"finish_reason":null}]}`
			testkit.WriteEncryptedChunk(t, ctx, conn, inferReq, pubKey, contentChunk)
			complete := protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: inferReq.RequestID,
				Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5},
			}
			completeData, _ := json.Marshal(complete)
			if wErr := conn.Write(ctx, websocket.MessageText, completeData); wErr != nil {
				return
			}
		case protocol.TypeCancel:
			// Losing/cancelled attempts are expected — ignore.
		}
	}
}

// TestDeferredCommit_PreContentFailover is the regression test for the
// OpenRouter-partner bug: provider A sends its boilerplate role chunk and then
// dies BEFORE producing content. Because nothing was written to the consumer
// yet, the coordinator must discard the preamble and retry invisibly on
// provider B — the consumer sees a clean 200 with B's content and NO in-band
// error event.
func TestDeferredCommit_PreContentFailover(t *testing.T) {
	ts, reg, _ := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "deferred-commit-model"
	pubKeyA := testkit.PublicKeyB64()
	pubKeyB := testkit.PublicKeyB64()

	// A reports a much higher decode TPS so routing picks it first.
	connA := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKeyA, 500.0)
	defer connA.Close(websocket.StatusNormalClosure, "")
	connB := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pubKeyB, 10.0)
	defer connB.Close(websocket.StatusNormalClosure, "")

	go runDeferredCommitProvider(ctx, t, connA, pubKeyA, true, "")
	go runDeferredCommitProvider(ctx, t, connB, pubKeyB, false, "from-provider-b")

	code, body, err := sendRequest(ctx, ts.URL, "test-key", model)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (invisible retry); body = %s", code, body)
	}
	if !strings.Contains(body, "from-provider-b") {
		t.Errorf("response must carry provider B's content; body:\n%s", body)
	}
	if strings.Contains(body, `"error"`) {
		t.Errorf("pre-content provider failure must NOT surface an in-band error; body:\n%s", body)
	}
	if strings.Contains(body, "provider crashed after preamble") {
		t.Errorf("provider A's error leaked to the consumer; body:\n%s", body)
	}
	// Exactly one assistant role preamble: A's held chunk was discarded with
	// the failed attempt, B's was emitted ahead of its content.
	if got := strings.Count(body, `"role":"assistant"`); got != 1 {
		t.Errorf("role preamble count = %d, want exactly 1 (failed attempt's preamble discarded); body:\n%s", got, body)
	}
}

// TestDispatch_FailoverContinuesPastLegacyCap proves deadline-bounded failover:
// the dispatch loop keeps trying fresh healthy providers well past the old
// 3-attempt cap, stopping only at candidate exhaustion (or the deadline). Six
// providers advertise higher TPS and crash pre-content (so routing prefers them
// first and fails over off each); one healthy provider advertises the lowest TPS
// and is therefore selected LAST. The request must still land on it. Under the
// legacy maxDispatchAttempts=3 the loop gave up after the first few failing
// providers and never reached the healthy one — even allowing for speculative
// double-dispatch, six bad providers ahead of it exceeds that budget.
func TestDispatch_FailoverContinuesPastLegacyCap(t *testing.T) {
	ts, reg, _ := setupLoadTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "failover-past-cap-model"

	// Six failing providers, descending high TPS so routing prefers them first
	// and fails over off each in turn.
	for _, tps := range []float64{600, 500, 400, 300, 200, 100} {
		pk := testkit.PublicKeyB64()
		conn := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, pk, tps)
		defer conn.Close(websocket.StatusNormalClosure, "")
		go runDeferredCommitProvider(ctx, t, conn, pk, true, "")
	}
	// One healthy provider with the lowest TPS — reachable only after the six
	// failing providers have each been tried and excluded.
	healthyPK := testkit.PublicKeyB64()
	healthyConn := connectAndPrepareProvider(t, ctx, ts.URL, reg, model, healthyPK, 10.0)
	defer healthyConn.Close(websocket.StatusNormalClosure, "")
	go runDeferredCommitProvider(ctx, t, healthyConn, healthyPK, false, "from-healthy")

	code, body, err := sendRequest(ctx, ts.URL, "test-key", model)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200 after failing over past six bad providers; body = %s", code, body)
	}
	if !strings.Contains(body, "from-healthy") {
		t.Errorf("failover must reach the healthy provider behind six failing ones; body:\n%s", body)
	}
	if strings.Contains(body, "provider crashed after preamble") {
		t.Errorf("a failing provider's error leaked to the consumer; body:\n%s", body)
	}
}
