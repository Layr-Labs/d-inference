package inference_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestDispatch_ClientGoneBetweenAttempts_RecordsClientGone (D2): the client
// has left by the time the ladder moves to its second attempt. Before the
// fix this fell through to the exhausted arm, wrote a 429 to a dead socket
// and counted the request as rate_limited on the OR-uptime counter. It must
// instead be recorded as a pre-content client_gone (with a deadline bucket),
// refund exactly once, and write nothing.
func TestDispatch_ClientGoneBetweenAttempts_RecordsClientGone(t *testing.T) {
	srv, _ := testServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.observation.SetDatadog(dd)

	const model = "d2-client-gone-model"
	// Socketless providers: the dispatch funnel reserves, encrypts, then fails
	// the write deterministically ("failed to send request to provider"), so
	// attempt 0 is a retryable send failure and the ladder reaches attempt 1.
	registerBuildsProvider(srv, "d2-p1", model)
	registerBuildsProvider(srv, "d2-p2", model)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // the client is already gone
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}")).WithContext(ctx)
	refunds := 0
	deadline := 5 * time.Second
	session := srv.NewDispatchSession(inference.DispatchRequest{
		Writer:                w,
		Request:               r,
		Model:                 model,
		PublicModel:           model,
		Body:                  []byte(`{"model":"` + model + `"}`),
		ConsumerKey:           "test-key",
		EstimatedPromptTokens: 6,
		RequestedMaxTokens:    64,
		Timing:                &registry.RequestTiming{ReceivedAt: time.Now()},
		Deadline:              deadline,
		SpeculativeAt:         deadline / 2,
		RefundReservation:     func() { refunds++ },
	})
	result := session.Run(ctx)

	if refunds != 1 {
		t.Errorf("reservation refunds = %d, want exactly 1", refunds)
	}
	if w.Body.Len() != 0 {
		t.Errorf("wrote a response to a dead socket: %s", w.Body.String())
	}
	if result.LastAttempt != 1 {
		t.Errorf("ladder stopped at attempt %d, want the client-gone exit at attempt 1", result.LastAttempt)
	}

	snap := srv.observation.Metrics().Snapshot()
	if got := snap.Counters[counterKey(infermetrics.ORViewCounter, observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: infermetrics.ORClientGone})]; got != 1 {
		t.Errorf("request_outcome_or_view{client_gone} = %d, want 1; counters=%v", got, snap.Counters)
	}
	if got := snap.Counters[counterKey(infermetrics.AttemptOutcomeCounter, observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: infermetrics.AttemptSendFailed})]; got != 1 {
		t.Errorf("attempt_outcome{send_failed} = %d, want 1 (attempt 0's socketless write); counters=%v", got, snap.Counters)
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	gone := findMetrics(packets, "routing.client_gone")
	if len(gone) != 1 {
		t.Fatalf("routing.client_gone packets = %d, want 1; packets=%v", len(gone), packets)
	}
	if !strings.Contains(gone[0], "phase:"+phaseBeforeFirstToken) || !strings.Contains(gone[0], "deadline_bucket:"+infermetrics.DeadlineUnderHalf) {
		t.Errorf("client_gone tags: %q, want phase:before_first_token and deadline_bucket:under_half", gone[0])
	}
	// metricRequestOutcome is a prefix of the OR-view name: match the sample
	// separator so only the legacy counter is inspected.
	if out := findMetrics(packets, infermetrics.RequestOutcomeMetric+":"); len(out) != 0 {
		t.Errorf("a client that left mid-ladder must not be counted on request_outcome: %v", out)
	}
	if got := sumMetric(t, packets, infermetrics.ORViewMetric, "model:"+model, "class:"+infermetrics.ORClientGone); got != 1 {
		t.Errorf("UDP request_outcome_or_view{client_gone} = %v, want 1", got)
	}
}
