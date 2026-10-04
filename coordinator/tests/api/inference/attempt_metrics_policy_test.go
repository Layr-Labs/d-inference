package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestAttemptOutcomeClass_Mapping(t *testing.T) {
	cases := []struct {
		name    string
		outcome store.InferenceRouteOutcome
		want    string
	}{
		{"pre-fill (non-terminal) is not counted", store.InferenceRouteOutcome{}, ""},
		{"success", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusSuccess}, infermetrics.AttemptSuccess},
		{"partial_success is a committed attempt", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusPartialSuccess, ErrorClass: "provider_error_after_commit"}, infermetrics.AttemptSuccess},
		{"client_gone", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusCancelled, ErrorClass: "client_gone"}, infermetrics.AttemptClientGone},
		{"speculative loser", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusCancelled, ErrorClass: "speculative_loser"}, infermetrics.AttemptSpeculativeLoser},
		{"first_chunk_timeout (timeout status)", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "first_chunk_timeout", ErrorReason: failure.ErrorReasonProviderError}, infermetrics.AttemptFirstChunkTimeout},
		{"accepted_timeout", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "accepted_timeout"}, infermetrics.AttemptFirstChunkTimeout},
		{"preamble_liveness_timeout", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "preamble_liveness_timeout"}, infermetrics.AttemptFirstChunkTimeout},
		{"queue_timeout is capacity", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "queue_timeout"}, infermetrics.AttemptCapacity},
		{"queue_deadline is capacity, not a kill", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "queue_deadline"}, infermetrics.AttemptCapacity},
		{"first_chunk_timeout via dispatch error class", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "first_chunk_timeout"}, infermetrics.AttemptFirstChunkTimeout},
		{"deadline_unreachable", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: routeoutcome.ErrorClassDeadlineUnreachable, ErrorReason: failure.ErrorReasonDeadlineUnreachable}, infermetrics.AttemptDeadlineUnreachable},
		{"client_error (jinja)", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: routeoutcome.ErrorClassClientError, ErrorReason: failure.ErrorReasonJinjaTemplate}, infermetrics.AttemptClientError},
		{"provider disconnect pre-commit", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "provider_disconnect_pre_commit", ErrorReason: failure.ErrorReasonProviderError, AdmittedButFailed: true}, infermetrics.AttemptDisconnect},
		{"ttft_too_slow is capacity", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "ttft_too_slow"}, infermetrics.AttemptCapacity},
		{"provider capacity 503 (token budget)", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: failure.ErrorReasonProviderError, ErrorReason: failure.ErrorReasonTokenBudgetExhaust, AdmittedButFailed: true, ErrorCode: 503}, infermetrics.AttemptCapacity},
		{"provider capacity 503 (busy)", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: failure.ErrorReasonProviderError, ErrorReason: failure.ErrorReasonCapacityBusy, AdmittedButFailed: true, ErrorCode: 503}, infermetrics.AttemptCapacity},
		{"media scratch refusal is capacity", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: failure.ErrorReasonProviderError, ErrorReason: failure.ErrorReasonMediaMemoryUnavailable, AdmittedButFailed: true, ErrorCode: 503}, infermetrics.AttemptCapacity},
		{"generic media scratch refusal is capacity", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "provider_error_before_response", ErrorReason: failure.ErrorReasonMediaMemoryUnavailable, AdmittedButFailed: true, ErrorCode: 503}, infermetrics.AttemptCapacity},
		{"model load failure is capacity", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: failure.ErrorReasonProviderError, ErrorReason: failure.ErrorReasonModelLoad, AdmittedButFailed: true}, infermetrics.AttemptCapacity},
		{"typed draining refusal (chat pre-commit) is capacity, not a fault", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: failure.ErrorReasonProviderError, ErrorReason: failure.ErrorReasonDraining, AdmittedButFailed: true, ErrorCode: 503}, infermetrics.AttemptCapacity},
		{"typed draining refusal (generic endpoint) is capacity, not a fault", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "provider_error_before_response", ErrorReason: failure.ErrorReasonDraining, AdmittedButFailed: true, ErrorCode: 503}, infermetrics.AttemptCapacity},
		{"genuine provider fault", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: failure.ErrorReasonProviderError, ErrorReason: failure.ErrorReasonProviderError, AdmittedButFailed: true, ErrorCode: 500}, infermetrics.AttemptFault},
		{"failed to send (never admitted)", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: failure.ErrorReasonProviderError, ErrorReason: failure.ErrorReasonProviderError}, infermetrics.AttemptSendFailed},
		{"generic endpoint provider error before response", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "provider_error_before_response", AdmittedButFailed: true}, infermetrics.AttemptFault},
		{"encryption_missing is other", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "encryption_missing"}, infermetrics.AttemptOther},
		{"unknown status is other", store.InferenceRouteOutcome{FinalStatus: "weird"}, infermetrics.AttemptOther},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := infermetrics.AttemptOutcomeClass(&tc.outcome); got != tc.want {
				t.Fatalf("attemptOutcomeClass = %q, want %q", got, tc.want)
			}
		})
	}
	if got := infermetrics.AttemptOutcomeClass(nil); got != "" {
		t.Fatalf("nil outcome class = %q, want empty", got)
	}
}

func TestORViewClassForCommittedOutcome(t *testing.T) {
	cases := []struct {
		name    string
		outcome store.InferenceRouteOutcome
		want    string
		wantOK  bool
	}{
		{"success", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusSuccess}, infermetrics.ORSuccess, true},
		{"provider error after commit is mid_stream", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusPartialSuccess, ErrorClass: "provider_error_after_commit"}, infermetrics.ORMidStream, true},
		{"provider disconnect after commit is mid_stream", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusPartialSuccess, ErrorClass: "provider_disconnect_after_commit"}, infermetrics.ORMidStream, true},
		{"stream timeout after commit is mid_stream", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusPartialSuccess, ErrorClass: "stream_timeout_after_commit"}, infermetrics.ORMidStream, true},
		{"provider incomplete after commit is mid_stream", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusPartialSuccess, ErrorClass: "provider_incomplete_after_commit"}, infermetrics.ORMidStream, true},
		{"client gone after commit (completed) is excluded", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusPartialSuccess, ErrorClass: routeoutcome.ErrorClassClientGoneAfterCommitCompleted}, infermetrics.ORClientGone, true},
		{"client gone after commit (error) is excluded", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusPartialSuccess, ErrorClass: "client_gone_after_commit_provider_error"}, infermetrics.ORClientGone, true},
		{"no terminal after cancel is excluded", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusPartialSuccess, ErrorClass: "no_terminal_after_cancel"}, infermetrics.ORClientGone, true},
		{"pre-content error is not a committed outcome", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "provider_error"}, "", false},
		{"pre-content timeout is not a committed outcome", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "first_chunk_timeout"}, "", false},
		{"pre-fill is not counted", store.InferenceRouteOutcome{}, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := infermetrics.ORViewClassForCommittedOutcome(&tc.outcome)
			if got != tc.want || ok != tc.wantOK {
				t.Fatalf("orViewClassForCommittedOutcome = (%q, %v), want (%q, %v)", got, ok, tc.want, tc.wantOK)
			}
		})
	}
}

func TestDeadlineBucket_AndORViewClass(t *testing.T) {
	budget := 10 * time.Second
	cases := []struct {
		elapsed time.Duration
		budget  time.Duration
		want    string
		wantOR  string
	}{
		{0, 0, infermetrics.DeadlineUnknown, infermetrics.ORClientGone},
		{time.Second, budget, infermetrics.DeadlineUnderHalf, infermetrics.ORClientGone},
		{4999 * time.Millisecond, budget, infermetrics.DeadlineUnderHalf, infermetrics.ORClientGone},
		{5 * time.Second, budget, infermetrics.DeadlineMid, infermetrics.ORClientGone},
		{7999 * time.Millisecond, budget, infermetrics.DeadlineMid, infermetrics.ORClientGone},
		{8 * time.Second, budget, infermetrics.DeadlineNear, infermetrics.ORTimeout},
		{9800 * time.Millisecond, budget, infermetrics.DeadlineNear, infermetrics.ORTimeout},
		{10 * time.Second, budget, infermetrics.DeadlineOver, infermetrics.ORTimeout},
		{30 * time.Second, budget, infermetrics.DeadlineOver, infermetrics.ORTimeout},
		{-time.Second, budget, infermetrics.DeadlineUnknown, infermetrics.ORClientGone},
	}
	for _, tc := range cases {
		got := infermetrics.DeadlineBucket(tc.elapsed, tc.budget)
		if got != tc.want {
			t.Errorf("deadlineBucket(%s, %s) = %q, want %q", tc.elapsed, tc.budget, got, tc.want)
		}
		if or := infermetrics.ORViewClassForClientGone(got); or != tc.wantOR {
			t.Errorf("orViewClassForClientGone(%q) = %q, want %q", got, or, tc.wantOR)
		}
	}
	if got := infermetrics.ORViewClassForClientGone(infermetrics.DeadlineNotApplicable); got != infermetrics.ORClientGone {
		t.Errorf("not_applicable bucket must be excluded, got %q", got)
	}
}

// TestAttemptOutcome_SilentProviderLadder: every provider stays silent, so the
// request-absolute first-content clock kills each dispatched attempt and the
// ladder ends in one uptime-neutral 429. Asserts the attempt-level funnel:
// exactly one attempt_outcome per dispatched attempt (amplification is
// computable), at least one first_chunk_timeout kill, exactly one
// request_outcome{rate_limited} and one request_outcome_or_view{rate_limited},
// a Retry-After sample from the exhausted writer, and an attempt-0 route
// latency sample — through the real HTTP + WebSocket path and a real UDP
// DogStatsD collector.
func TestAttemptOutcome_SilentProviderLadder(t *testing.T) {
	reg, _, srv, ts := setupTTFTFailoverServerWithConfig(t, TestServerConfig{
		FirstContentDeadlineBase: 400 * time.Millisecond,
	})
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.observation.SetDatadog(dd)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	const model = "attempt-outcome-silent-model"
	silent := func(context.Context, *failoverProvider, protocol.InferenceRequestMessage, []byte) {}
	providers := make([]*failoverProvider, 0, 3)
	for i := range 3 {
		providers = append(providers, startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: fmt.Sprintf("silent-%d", i), Version: "0.6.20", DecodeTPS: 100,
			Models: []failoverModelSpec{{ID: model}}, Script: silent,
		}))
	}

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (first-content clock exhausted); body = %s", status, body)
	}

	dispatched := 0
	for _, fp := range providers {
		dispatched += fp.dispatchCount()
	}
	if dispatched == 0 {
		t.Fatal("no provider was dispatched")
	}
	classes := []string{infermetrics.AttemptSuccess, infermetrics.AttemptFirstChunkTimeout, infermetrics.AttemptDeadlineUnreachable, infermetrics.AttemptCapacity, infermetrics.AttemptClientError, infermetrics.AttemptFault, infermetrics.AttemptSendFailed, infermetrics.AttemptDisconnect, infermetrics.AttemptClientGone, infermetrics.AttemptSpeculativeLoser, infermetrics.AttemptOther}
	attemptTotal := func(snap observation.MetricsSnapshot) int64 {
		var total int64
		for _, class := range classes {
			total += snap.Counters[counterKey(infermetrics.AttemptOutcomeCounter, observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: class})]
		}
		return total
	}
	snap := waitForCounters(t, srv, 3*time.Second, func(s observation.MetricsSnapshot) bool {
		return attemptTotal(s) >= int64(dispatched)
	})
	if got := attemptTotal(snap); got != int64(dispatched) {
		t.Fatalf("attempt_outcome total = %d, want exactly one per dispatched attempt (%d); counters=%v",
			got, dispatched, snap.Counters)
	}
	kills := snap.Counters[counterKey(infermetrics.AttemptOutcomeCounter, observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: infermetrics.AttemptFirstChunkTimeout})]
	if kills < 1 {
		t.Fatalf("attempt_outcome{first_chunk_timeout} = %d, want >= 1; counters=%v", kills, snap.Counters)
	}
	if got := snap.Counters[counterKey(infermetrics.ORViewCounter, observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: infermetrics.ORRateLimited})]; got != 1 {
		t.Fatalf("request_outcome_or_view{rate_limited} = %d, want 1; counters=%v", got, snap.Counters)
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, infermetrics.AttemptOutcomeMetric, "model:"+model, "class:"+infermetrics.AttemptFirstChunkTimeout); got != float64(kills) {
		t.Errorf("UDP attempt_outcome{first_chunk_timeout} = %v, want %d; packets=%v", got, kills, findMetrics(packets, infermetrics.AttemptOutcomeMetric))
	}
	if got := sumMetric(t, packets, infermetrics.AttemptOutcomeMetric, "model:"+model); got != float64(dispatched) {
		t.Errorf("UDP attempt_outcome total = %v, want %d", got, dispatched)
	}
	if got := sumMetric(t, packets, infermetrics.RequestOutcomeMetric, "model:"+model, "class:"+infermetrics.ORRateLimited); got != 1 {
		t.Errorf("UDP request_outcome{rate_limited} = %v, want 1; packets=%v", got, findMetrics(packets, infermetrics.RequestOutcomeMetric))
	}
	if got := sumMetric(t, packets, infermetrics.ORViewMetric, "model:"+model, "class:"+infermetrics.ORRateLimited); got != 1 {
		t.Errorf("UDP request_outcome_or_view{rate_limited} = %v, want 1", got)
	}
	if !hasMetric(findMetrics(packets, infermetrics.RouteLatencyMetric), "model:"+model) {
		t.Errorf("missing routing.route_latency_ms{model} sample; packets=%v", packets)
	}
	for _, p := range packets {
		if strings.Contains(p, "provider_id:") &&
			(strings.Contains(p, infermetrics.AttemptOutcomeMetric) || strings.Contains(p, infermetrics.ORViewMetric) ||
				strings.Contains(p, infermetrics.RouteLatencyMetric)) {
			t.Errorf("new series must never carry a provider id: %q", p)
		}
	}
}

// TestUnknownFrames_CountedByKindAndVersion: a provider sends chunk /
// complete / error frames for a request the coordinator does not know. Each
// must be counted on inference.unknown_frames by frame kind and the provider's
// binary version — never its id.
func TestUnknownFrames_CountedByKindAndVersion(t *testing.T) {
	reg, _, srv, ts := setupTTFTFailoverServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.observation.SetDatadog(dd)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "unknown-frames-model"
	const version = "0.6.20"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "zombie", Version: version, DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}},
	})
	const bogus = "no-such-request-id"
	frames := []any{
		protocol.InferenceResponseChunkMessage{Type: protocol.TypeInferenceResponseChunk, RequestID: bogus, Data: "data: {}\n\n"},
		protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: bogus},
		protocol.InferenceErrorMessage{Type: protocol.TypeInferenceError, RequestID: bogus, Error: "zombie", StatusCode: 500, FailureCode: protocol.FailureCodeGenerationFailure},
	}
	for _, frame := range frames {
		data, err := json.Marshal(frame)
		if err != nil {
			t.Fatal(err)
		}
		if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatalf("write frame: %v", err)
		}
	}

	key := func(kind string) string {
		return counterKey(cancellation.MetricUnknownFramesCounter,
			observation.MetricLabel{Name: "kind", Value: kind}, observation.MetricLabel{Name: "provider_version", Value: "0.6.x"})
	}
	snap := waitForCounters(t, srv, 3*time.Second, func(s observation.MetricsSnapshot) bool {
		return s.Counters[key(cancellation.UnknownFrameKindChunk)] == 1 &&
			s.Counters[key(cancellation.UnknownFrameKindComplete)] == 1 &&
			s.Counters[key(cancellation.UnknownFrameKindError)] == 1
	})
	for _, kind := range []string{cancellation.UnknownFrameKindChunk, cancellation.UnknownFrameKindComplete, cancellation.UnknownFrameKindError} {
		if got := snap.Counters[key(kind)]; got != 1 {
			t.Errorf("unknown_frames{kind=%s,provider_version=%s} = %d, want 1; counters=%v", kind, version, got, snap.Counters)
		}
	}

	_ = dd.Statsd.Flush()
	packets := findMetrics(collector.drain(), cancellation.MetricUnknownFrames)
	for _, kind := range []string{cancellation.UnknownFrameKindChunk, cancellation.UnknownFrameKindComplete, cancellation.UnknownFrameKindError} {
		if got := sumMetric(t, packets, cancellation.MetricUnknownFrames, "kind:"+kind, "provider_version:0.6.x"); got != 1 {
			t.Errorf("UDP unknown_frames{kind:%s} = %v, want 1; packets=%v", kind, got, packets)
		}
	}
	for _, p := range packets {
		if strings.Contains(p, "provider_id:") || strings.Contains(p, fp.registryID) || strings.Contains(p, bogus) {
			t.Errorf("unknown_frames must not carry provider or request identity: %q", p)
		}
	}
}

func TestQueueOutcomeClass_Mapping(t *testing.T) {
	cases := []struct {
		name    string
		outcome store.InferenceRouteOutcome
		want    string
	}{
		{"pre-fill (non-terminal) is not counted", store.InferenceRouteOutcome{}, ""},
		{"client gone while queued", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusCancelled, ErrorClass: "client_gone"}, infermetrics.QueueClientGone},
		{"queue_deadline", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "queue_deadline"}, infermetrics.QueueDeadline},
		{"queue_timeout", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "queue_timeout"}, infermetrics.QueueTimeout},
		{"ttft_too_slow", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "ttft_too_slow"}, infermetrics.QueueTTFTTooSlow},
		{"tool constraint unavailable", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "model_capability_unsupported"}, infermetrics.QueueCapabilityUnsupported},
		{"unknown exit class is other", store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusError, ErrorClass: "something_new"}, infermetrics.QueueOther},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := infermetrics.QueueOutcomeClass(&tc.outcome); got != tc.want {
				t.Fatalf("queueOutcomeClass = %q, want %q", got, tc.want)
			}
		})
	}
	if got := infermetrics.QueueOutcomeClass(nil); got != "" {
		t.Fatalf("nil outcome class = %q, want empty", got)
	}
}

// TestEmitAttemptOutcomeMetric_QueueExitIsNotAnAttempt: the same terminal
// outcome reaches the funnel twice — once flagged as a queue-wait exit (no
// provider attempt was dispatched) and once as a dispatched attempt. Only the
// latter may increment attempt_outcome; the former lands on queue_outcome.
// Both the in-process registry and the DogStatsD sink are asserted.
func TestEmitAttemptOutcomeMetric_QueueExitIsNotAnAttempt(t *testing.T) {
	srv, _ := testServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.observation.SetDatadog(dd)

	const model = "queue-exit-unit-model"
	attemptTotal := func(snap observation.MetricsSnapshot) int64 {
		var total int64
		for key, v := range snap.Counters {
			if strings.HasPrefix(key, infermetrics.AttemptOutcomeCounter) && strings.Contains(key, "model="+model) {
				total += v
			}
		}
		return total
	}

	queued := &store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "queue_deadline", ErrorCode: http.StatusGatewayTimeout, QueueExit: true}
	srv.NewMetrics().AttemptOutcome(model, queued)
	snap := srv.observation.Metrics().Snapshot()
	if got := attemptTotal(snap); got != 0 {
		t.Fatalf("attempt_outcome after a queue exit = %d, want 0; counters=%v", got, snap.Counters)
	}
	if got := snap.Counters[counterKey(infermetrics.QueueOutcomeCounter, observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: infermetrics.QueueDeadline})]; got != 1 {
		t.Fatalf("queue_outcome{queue_deadline} = %d, want 1; counters=%v", got, snap.Counters)
	}

	// A queue exit that never became terminal is not counted anywhere.
	srv.NewMetrics().AttemptOutcome(model, &store.InferenceRouteOutcome{QueueExit: true})

	// The same class from a DISPATCHED attempt still counts as an attempt.
	dispatched := &store.InferenceRouteOutcome{FinalStatus: routeoutcome.FinalStatusTimeout, ErrorClass: "queue_deadline", ErrorCode: http.StatusGatewayTimeout}
	srv.NewMetrics().AttemptOutcome(model, dispatched)
	snap = srv.observation.Metrics().Snapshot()
	if got := attemptTotal(snap); got != 1 {
		t.Fatalf("attempt_outcome after a dispatched terminal = %d, want 1; counters=%v", got, snap.Counters)
	}
	if got := snap.Counters[counterKey(infermetrics.AttemptOutcomeCounter, observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: infermetrics.AttemptCapacity})]; got != 1 {
		t.Fatalf("attempt_outcome{capacity} = %d, want 1; counters=%v", got, snap.Counters)
	}
	var queueTotal int64
	for key, v := range snap.Counters {
		if strings.HasPrefix(key, infermetrics.QueueOutcomeCounter) && strings.Contains(key, "model="+model) {
			queueTotal += v
		}
	}
	if queueTotal != 1 {
		t.Fatalf("queue_outcome total = %d, want exactly the one queue exit; counters=%v", queueTotal, snap.Counters)
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, infermetrics.QueueOutcomeMetric, "model:"+model, "class:"+infermetrics.QueueDeadline); got != 1 {
		t.Errorf("UDP queue_outcome{queue_deadline} = %v, want 1; packets=%v", got, findMetrics(packets, infermetrics.QueueOutcomeMetric))
	}
	if got := sumMetric(t, packets, infermetrics.AttemptOutcomeMetric, "model:"+model); got != 1 {
		t.Errorf("UDP attempt_outcome total = %v, want 1 (the dispatched terminal only); packets=%v", got, findMetrics(packets, infermetrics.AttemptOutcomeMetric))
	}
}

// TestQueuedExit_LiveQueueDeadline_CountsOnQueueOutcome drives the REAL HTTP
// + WebSocket path: the single slot is saturated, an explicit prefer-owner
// request queues, and the
// first-content clock expires inside the queue wait. Nothing was dispatched,
// so attempt_outcome must stay at zero for the model while queue_outcome
// records exactly one queue_deadline — the amplification denominator must not
// move for a request no provider ever received.
func TestQueuedExit_LiveQueueDeadline_CountsOnQueueOutcome(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const model = "queue-exit-live-model"
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	// Install the client before any provider connects: heartbeat telemetry
	// reads s.dd on the provider read loop, so setting it afterwards races.
	srv, _, _, ts := queuedFleetHarnessConfigured(t, ctx, TestServerConfig{FirstContentDeadlineBase: 400 * time.Millisecond}, model, func(s *serverFixture) {
		s.observation.SetDatadog(dd)
	})

	res := chatRequestWithID(ctx, ts.URL, model, "queue-exit-live", "prefer")
	if res.err != nil {
		t.Fatalf("chat request: %v", res.err)
	}
	if res.status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body=%s", res.status, res.body)
	}

	queueKey := counterKey(infermetrics.QueueOutcomeCounter, observation.MetricLabel{Name: "model", Value: model}, observation.MetricLabel{Name: "class", Value: infermetrics.QueueDeadline})
	snap := waitForCounters(t, srv, 3*time.Second, func(s observation.MetricsSnapshot) bool {
		return s.Counters[queueKey] >= 1
	})
	if got := snap.Counters[queueKey]; got != 1 {
		t.Fatalf("queue_outcome{queue_deadline} = %d, want 1; counters=%v", got, snap.Counters)
	}
	for key, v := range snap.Counters {
		if strings.HasPrefix(key, infermetrics.AttemptOutcomeCounter) && strings.Contains(key, "model="+model) && v != 0 {
			t.Fatalf("attempt_outcome incremented for a queue-only request: %s=%d; counters=%v", key, v, snap.Counters)
		}
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, infermetrics.QueueOutcomeMetric, "model:"+model, "class:"+infermetrics.QueueDeadline); got != 1 {
		t.Errorf("UDP queue_outcome{queue_deadline} = %v, want 1; packets=%v", got, findMetrics(packets, infermetrics.QueueOutcomeMetric))
	}
	if got := sumMetric(t, packets, infermetrics.AttemptOutcomeMetric, "model:"+model); got != 0 {
		t.Errorf("UDP attempt_outcome total = %v, want 0 for a queue-only request; packets=%v", got, findMetrics(packets, infermetrics.AttemptOutcomeMetric))
	}
}
