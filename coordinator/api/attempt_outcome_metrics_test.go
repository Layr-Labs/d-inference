package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// metricSampleValue parses the numeric value out of a DogStatsD packet
// ("d_inference.<name>:<value>|<type>|#tags"). The client aggregates identical
// counter samples inside a flush window into one packet whose value is the
// sum, so tests must add values rather than count packets.
func metricSampleValue(t *testing.T, packet string) float64 {
	t.Helper()
	colon := strings.Index(packet, ":")
	pipe := strings.Index(packet, "|")
	if colon < 0 || pipe < 0 || pipe <= colon {
		t.Fatalf("unparseable DogStatsD packet %q", packet)
	}
	v, err := strconv.ParseFloat(packet[colon+1:pipe], 64)
	if err != nil {
		t.Fatalf("packet %q: bad value: %v", packet, err)
	}
	return v
}

// sumMetric adds the values of every packet that carries the metric name and
// ALL of the given tag substrings.
func sumMetric(t *testing.T, packets []string, metric string, tags ...string) float64 {
	t.Helper()
	total := 0.0
	for _, p := range packets {
		if !strings.Contains(p, metric+":") {
			continue
		}
		match := true
		for _, tag := range tags {
			if !strings.Contains(p, tag) {
				match = false
				break
			}
		}
		if match {
			total += metricSampleValue(t, p)
		}
	}
	return total
}

func counterKey(name string, labels ...MetricLabel) string {
	return metricKey(name, labels)
}

func TestAttemptOutcomeClass_Mapping(t *testing.T) {
	cases := []struct {
		name    string
		outcome store.InferenceRouteOutcome
		want    string
	}{
		{"pre-fill (non-terminal) is not counted", store.InferenceRouteOutcome{}, ""},
		{"success", store.InferenceRouteOutcome{FinalStatus: finalStatusSuccess}, attemptClassSuccess},
		{"partial_success is a committed attempt", store.InferenceRouteOutcome{FinalStatus: finalStatusPartialSuccess, ErrorClass: "provider_error_after_commit"}, attemptClassSuccess},
		{"client_gone", store.InferenceRouteOutcome{FinalStatus: finalStatusCancelled, ErrorClass: "client_gone"}, attemptClassClientGone},
		{"speculative loser", store.InferenceRouteOutcome{FinalStatus: finalStatusCancelled, ErrorClass: "speculative_loser"}, attemptClassSpeculativeLoser},
		{"first_chunk_timeout (timeout status)", store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: "first_chunk_timeout", ErrorReason: errorReasonProviderError}, attemptClassFirstChunkTimeout},
		{"accepted_timeout", store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: "accepted_timeout"}, attemptClassFirstChunkTimeout},
		{"preamble_liveness_timeout", store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: "preamble_liveness_timeout"}, attemptClassFirstChunkTimeout},
		{"queue_timeout is capacity", store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: "queue_timeout"}, attemptClassCapacity},
		{"queue_deadline is capacity, not a kill", store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: "queue_deadline"}, attemptClassCapacity},
		{"first_chunk_timeout via dispatch error class", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "first_chunk_timeout"}, attemptClassFirstChunkTimeout},
		{"deadline_unreachable", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: errorClassDeadlineUnreachable, ErrorReason: errorReasonDeadlineUnreachable}, attemptClassDeadlineUnreachable},
		{"client_error (jinja)", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: errorClassClientError, ErrorReason: errorReasonJinjaTemplate}, attemptClassClientError},
		{"provider disconnect pre-commit", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "provider_disconnect_pre_commit", ErrorReason: errorReasonProviderError, AdmittedButFailed: true}, attemptClassDisconnect},
		{"ttft_too_slow is capacity", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "ttft_too_slow"}, attemptClassCapacity},
		{"provider capacity 503 (token budget)", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: errorReasonProviderError, ErrorReason: errorReasonTokenBudgetExhaust, AdmittedButFailed: true, ErrorCode: 503}, attemptClassCapacity},
		{"provider capacity 503 (busy)", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: errorReasonProviderError, ErrorReason: errorReasonCapacityBusy, AdmittedButFailed: true, ErrorCode: 503}, attemptClassCapacity},
		{"model load failure is capacity", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: errorReasonProviderError, ErrorReason: errorReasonModelLoad, AdmittedButFailed: true}, attemptClassCapacity},
		{"typed draining refusal (chat pre-commit) is capacity, not a fault", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: errorReasonProviderError, ErrorReason: errorReasonDraining, AdmittedButFailed: true, ErrorCode: 503}, attemptClassCapacity},
		{"typed draining refusal (generic endpoint) is capacity, not a fault", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "provider_error_before_response", ErrorReason: errorReasonDraining, AdmittedButFailed: true, ErrorCode: 503}, attemptClassCapacity},
		{"genuine provider fault", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: errorReasonProviderError, ErrorReason: errorReasonProviderError, AdmittedButFailed: true, ErrorCode: 500}, attemptClassFault},
		{"failed to send (never admitted)", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: errorReasonProviderError, ErrorReason: errorReasonProviderError}, attemptClassSendFailed},
		{"generic endpoint provider error before response", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "provider_error_before_response", AdmittedButFailed: true}, attemptClassFault},
		{"encryption_missing is other", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "encryption_missing"}, attemptClassOther},
		{"unknown status is other", store.InferenceRouteOutcome{FinalStatus: "weird"}, attemptClassOther},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := attemptOutcomeClass(&tc.outcome); got != tc.want {
				t.Fatalf("attemptOutcomeClass = %q, want %q", got, tc.want)
			}
		})
	}
	if got := attemptOutcomeClass(nil); got != "" {
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
		{"success", store.InferenceRouteOutcome{FinalStatus: finalStatusSuccess}, orClassSuccess, true},
		{"provider error after commit is mid_stream", store.InferenceRouteOutcome{FinalStatus: finalStatusPartialSuccess, ErrorClass: "provider_error_after_commit"}, orClassMidStream, true},
		{"provider disconnect after commit is mid_stream", store.InferenceRouteOutcome{FinalStatus: finalStatusPartialSuccess, ErrorClass: "provider_disconnect_after_commit"}, orClassMidStream, true},
		{"stream timeout after commit is mid_stream", store.InferenceRouteOutcome{FinalStatus: finalStatusPartialSuccess, ErrorClass: "stream_timeout_after_commit"}, orClassMidStream, true},
		{"provider incomplete after commit is mid_stream", store.InferenceRouteOutcome{FinalStatus: finalStatusPartialSuccess, ErrorClass: "provider_incomplete_after_commit"}, orClassMidStream, true},
		{"client gone after commit (completed) is excluded", store.InferenceRouteOutcome{FinalStatus: finalStatusPartialSuccess, ErrorClass: errorClassClientGoneAfterCommitCompleted}, orClassClientGone, true},
		{"client gone after commit (error) is excluded", store.InferenceRouteOutcome{FinalStatus: finalStatusPartialSuccess, ErrorClass: "client_gone_after_commit_provider_error"}, orClassClientGone, true},
		{"no terminal after cancel is excluded", store.InferenceRouteOutcome{FinalStatus: finalStatusPartialSuccess, ErrorClass: "no_terminal_after_cancel"}, orClassClientGone, true},
		{"pre-content error is not a committed outcome", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "provider_error"}, "", false},
		{"pre-content timeout is not a committed outcome", store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: "first_chunk_timeout"}, "", false},
		{"pre-fill is not counted", store.InferenceRouteOutcome{}, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := orViewClassForCommittedOutcome(&tc.outcome)
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
		{0, 0, deadlineBucketUnknown, orClassClientGone},
		{time.Second, budget, deadlineBucketUnderHalf, orClassClientGone},
		{4999 * time.Millisecond, budget, deadlineBucketUnderHalf, orClassClientGone},
		{5 * time.Second, budget, deadlineBucketMid, orClassClientGone},
		{7999 * time.Millisecond, budget, deadlineBucketMid, orClassClientGone},
		{8 * time.Second, budget, deadlineBucketNearDeadline, orClassTimeout},
		{9800 * time.Millisecond, budget, deadlineBucketNearDeadline, orClassTimeout},
		{10 * time.Second, budget, deadlineBucketOver, orClassTimeout},
		{30 * time.Second, budget, deadlineBucketOver, orClassTimeout},
		{-time.Second, budget, deadlineBucketUnknown, orClassClientGone},
	}
	for _, tc := range cases {
		got := deadlineBucket(tc.elapsed, tc.budget)
		if got != tc.want {
			t.Errorf("deadlineBucket(%s, %s) = %q, want %q", tc.elapsed, tc.budget, got, tc.want)
		}
		if or := orViewClassForClientGone(got); or != tc.wantOR {
			t.Errorf("orViewClassForClientGone(%q) = %q, want %q", got, or, tc.wantOR)
		}
	}
	if got := orViewClassForClientGone(deadlineBucketNotApplicable); got != orClassClientGone {
		t.Errorf("not_applicable bucket must be excluded, got %q", got)
	}
}

func TestSanitizeVersionTag(t *testing.T) {
	cases := map[string]string{
		"":                       "unknown",
		"  ":                     "unknown",
		"0.6.20":                 "0.6.x",
		"v0.8.16":                "0.8.x",
		"0.8.16-rc.1":            "prerelease",
		"0.8.16-beta.2":          "prerelease",
		"build-a1":               "other",
		"0.8.16-abc123":          "other",
		"0.8.16-rc":              "other",
		"0.8.16+build.5":         "other",
		"1.2":                    "other",
		"1.2.3.4":                "other",
		"01.2.3":                 "other",
		"0.6.20 evil:tag":        "other",
		"0.6,20":                 "other",
		strings.Repeat("9", 40):  "other",
		strings.Repeat("a", 200): "other",
	}
	for in, want := range cases {
		if got := sanitizeVersionTag(in); got != want {
			t.Errorf("sanitizeVersionTag(%q) = %q, want %q", in, got, want)
		}
	}
	if got := providerVersionTag(nil); got != "unknown" {
		t.Errorf("providerVersionTag(nil) = %q, want unknown", got)
	}
}

// waitForCounter polls the in-process metrics snapshot until pred holds or
// the deadline passes; returns the final snapshot.
func waitForCounters(t *testing.T, srv *Server, timeout time.Duration, pred func(MetricsSnapshot) bool) MetricsSnapshot {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		snap := srv.metrics.Snapshot()
		if pred(snap) || time.Now().After(deadline) {
			return snap
		}
		time.Sleep(20 * time.Millisecond)
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
	reg, _, srv, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{
		FirstContentDeadlineBase: 400 * time.Millisecond,
	})
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

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
	classes := []string{
		attemptClassSuccess, attemptClassFirstChunkTimeout, attemptClassDeadlineUnreachable,
		attemptClassCapacity, attemptClassClientError, attemptClassFault, attemptClassSendFailed,
		attemptClassDisconnect, attemptClassClientGone, attemptClassSpeculativeLoser, attemptClassOther,
	}
	attemptTotal := func(snap MetricsSnapshot) int64 {
		var total int64
		for _, class := range classes {
			total += snap.Counters[counterKey(metricAttemptOutcomeCounter,
				MetricLabel{"model", model}, MetricLabel{"class", class})]
		}
		return total
	}
	snap := waitForCounters(t, srv, 3*time.Second, func(s MetricsSnapshot) bool {
		return attemptTotal(s) >= int64(dispatched)
	})
	if got := attemptTotal(snap); got != int64(dispatched) {
		t.Fatalf("attempt_outcome total = %d, want exactly one per dispatched attempt (%d); counters=%v",
			got, dispatched, snap.Counters)
	}
	kills := snap.Counters[counterKey(metricAttemptOutcomeCounter,
		MetricLabel{"model", model}, MetricLabel{"class", attemptClassFirstChunkTimeout})]
	if kills < 1 {
		t.Fatalf("attempt_outcome{first_chunk_timeout} = %d, want >= 1; counters=%v", kills, snap.Counters)
	}
	if got := snap.Counters[counterKey(metricRequestOutcomeORViewCounter,
		MetricLabel{"model", model}, MetricLabel{"class", orClassRateLimited})]; got != 1 {
		t.Fatalf("request_outcome_or_view{rate_limited} = %d, want 1; counters=%v", got, snap.Counters)
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, metricAttemptOutcome, "model:"+model, "class:"+attemptClassFirstChunkTimeout); got != float64(kills) {
		t.Errorf("UDP attempt_outcome{first_chunk_timeout} = %v, want %d; packets=%v", got, kills, findMetrics(packets, metricAttemptOutcome))
	}
	if got := sumMetric(t, packets, metricAttemptOutcome, "model:"+model); got != float64(dispatched) {
		t.Errorf("UDP attempt_outcome total = %v, want %d", got, dispatched)
	}
	if got := sumMetric(t, packets, metricRequestOutcome, "model:"+model, "class:"+orClassRateLimited); got != 1 {
		t.Errorf("UDP request_outcome{rate_limited} = %v, want 1; packets=%v", got, findMetrics(packets, metricRequestOutcome))
	}
	if got := sumMetric(t, packets, metricRequestOutcomeORView, "model:"+model, "class:"+orClassRateLimited); got != 1 {
		t.Errorf("UDP request_outcome_or_view{rate_limited} = %v, want 1", got)
	}
	if !hasMetric(findMetrics(packets, metricRouteLatency), "model:"+model) {
		t.Errorf("missing routing.route_latency_ms{model} sample; packets=%v", packets)
	}
	for _, p := range packets {
		if strings.Contains(p, "provider_id:") &&
			(strings.Contains(p, metricAttemptOutcome) || strings.Contains(p, metricRequestOutcomeORView) ||
				strings.Contains(p, metricRouteLatency)) {
			t.Errorf("new series must never carry a provider id: %q", p)
		}
	}
}

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
	srv.SetDatadog(dd)

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
	d := &dispatchState{
		s:                     srv,
		w:                     w,
		r:                     r,
		model:                 model,
		publicModel:           model,
		rawBody:               []byte(`{"model":"` + model + `"}`),
		consumerKey:           "test-key",
		estimatedPromptTokens: 6,
		requestedMaxTokens:    64,
		timing:                &registry.RequestTiming{ReceivedAt: time.Now()},
		deadline:              deadline,
		speculativeAt:         deadline / 2,
		refundReservation:     func() { refunds++ },
		excludeProviders:      make(map[string]struct{}),
	}
	d.run()

	if refunds != 1 {
		t.Errorf("reservation refunds = %d, want exactly 1", refunds)
	}
	if w.Body.Len() != 0 {
		t.Errorf("wrote a response to a dead socket: %s", w.Body.String())
	}
	if d.attempt != 1 {
		t.Errorf("ladder stopped at attempt %d, want the client-gone exit at attempt 1", d.attempt)
	}

	snap := srv.metrics.Snapshot()
	if got := snap.Counters[counterKey(metricRequestOutcomeORViewCounter,
		MetricLabel{"model", model}, MetricLabel{"class", orClassClientGone})]; got != 1 {
		t.Errorf("request_outcome_or_view{client_gone} = %d, want 1; counters=%v", got, snap.Counters)
	}
	if got := snap.Counters[counterKey(metricAttemptOutcomeCounter,
		MetricLabel{"model", model}, MetricLabel{"class", attemptClassSendFailed})]; got != 1 {
		t.Errorf("attempt_outcome{send_failed} = %d, want 1 (attempt 0's socketless write); counters=%v", got, snap.Counters)
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	gone := findMetrics(packets, "routing.client_gone")
	if len(gone) != 1 {
		t.Fatalf("routing.client_gone packets = %d, want 1; packets=%v", len(gone), packets)
	}
	if !strings.Contains(gone[0], "phase:"+phaseBeforeFirstToken) || !strings.Contains(gone[0], "deadline_bucket:"+deadlineBucketUnderHalf) {
		t.Errorf("client_gone tags: %q, want phase:before_first_token and deadline_bucket:under_half", gone[0])
	}
	// metricRequestOutcome is a prefix of the OR-view name: match the sample
	// separator so only the legacy counter is inspected.
	if out := findMetrics(packets, metricRequestOutcome+":"); len(out) != 0 {
		t.Errorf("a client that left mid-ladder must not be counted on request_outcome: %v", out)
	}
	if got := sumMetric(t, packets, metricRequestOutcomeORView, "model:"+model, "class:"+orClassClientGone); got != 1 {
		t.Errorf("UDP request_outcome_or_view{client_gone} = %v, want 1", got)
	}
}

// TestRecordRejection_MirrorsORView: the pre-dispatch rejection arm emits one
// request_outcome_or_view increment per rejection, classed like
// request_outcome and tagged with the RESOLVED model only (the requested name
// is client-controlled and must never mint a tag value).
func TestRecordRejection_MirrorsORView(t *testing.T) {
	srv, _ := testServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	const model = "or-view-mirror-model"
	srv.recordRejection(rejectionInfo{
		stage: "preflight_capacity", reasonCode: "machine_busy", httpStatus: http.StatusTooManyRequests,
		requestedModel: "client-typed-alias", resolvedModel: model, retryAfterMs: 7000,
	})
	srv.recordRejection(rejectionInfo{
		stage: "validation", reasonCode: "bad_request", httpStatus: http.StatusBadRequest,
		requestedModel: "client-typed-alias", resolvedModel: model,
	})

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, metricRequestOutcomeORView, "model:"+model, "class:"+orClassRateLimited); got != 1 {
		t.Errorf("request_outcome_or_view{rate_limited} = %v, want 1; packets=%v", got, findMetrics(packets, metricRequestOutcomeORView))
	}
	if got := sumMetric(t, packets, metricRequestOutcomeORView, "model:"+model, "class:"+orClassClientError); got != 1 {
		t.Errorf("request_outcome_or_view{client_error} = %v, want 1; packets=%v", got, findMetrics(packets, metricRequestOutcomeORView))
	}
	for _, p := range findMetrics(packets, metricRequestOutcomeORView) {
		if strings.Contains(p, "client-typed-alias") {
			t.Errorf("request_outcome_or_view must tag the RESOLVED model only: %q", p)
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
	srv.SetDatadog(dd)

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
		protocol.InferenceErrorMessage{Type: protocol.TypeInferenceError, RequestID: bogus, Error: "zombie", StatusCode: 500},
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
		return counterKey(metricUnknownFramesCounter,
			MetricLabel{"kind", kind}, MetricLabel{"provider_version", "0.6.x"})
	}
	snap := waitForCounters(t, srv, 3*time.Second, func(s MetricsSnapshot) bool {
		return s.Counters[key(unknownFrameKindChunk)] == 1 &&
			s.Counters[key(unknownFrameKindComplete)] == 1 &&
			s.Counters[key(unknownFrameKindError)] == 1
	})
	for _, kind := range []string{unknownFrameKindChunk, unknownFrameKindComplete, unknownFrameKindError} {
		if got := snap.Counters[key(kind)]; got != 1 {
			t.Errorf("unknown_frames{kind=%s,provider_version=%s} = %d, want 1; counters=%v", kind, version, got, snap.Counters)
		}
	}

	_ = dd.Statsd.Flush()
	packets := findMetrics(collector.drain(), metricUnknownFrames)
	for _, kind := range []string{unknownFrameKindChunk, unknownFrameKindComplete, unknownFrameKindError} {
		if got := sumMetric(t, packets, metricUnknownFrames, "kind:"+kind, "provider_version:0.6.x"); got != 1 {
			t.Errorf("UDP unknown_frames{kind:%s} = %v, want 1; packets=%v", kind, got, packets)
		}
	}
	for _, p := range packets {
		if strings.Contains(p, "provider_id:") || strings.Contains(p, fp.registryID) || strings.Contains(p, bogus) {
			t.Errorf("unknown_frames must not carry provider or request identity: %q", p)
		}
	}
}

// TestFleetGauges_QueueDepth exercises the gauge emitter StartDDGaugeLoop
// calls: a queued request shows up on the per-model depth / oldest-age gauges.
func TestFleetGauges_QueueDepth(t *testing.T) {
	srv, _ := testServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	const model = "fleet-gauge-model"
	registerBuildsProvider(srv, "fg-healthy", model)

	q := srv.registry.Queue()
	queued := &registry.QueuedRequest{RequestID: "fg-queued-1", Model: model}
	if err := q.Enqueue(queued); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	defer q.Remove(queued.RequestID, model)
	time.Sleep(20 * time.Millisecond)

	srv.emitPerModelQueueGauges(srv.registry.ModelProviderSnapshot())

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, metricQueueDepthByModel, "model:"+model); got != 1 {
		t.Errorf("request_queue.depth_by_model{%s} = %v, want 1; packets=%v", model, got, findMetrics(packets, metricQueueDepthByModel))
	}
	ages := findMetrics(packets, metricQueueOldestAgeMs)
	if !hasMetric(ages, "model:"+model) {
		t.Errorf("missing request_queue.oldest_age_ms{model}; packets=%v", packets)
	}
	for _, p := range ages {
		if strings.Contains(p, "model:"+model) && metricSampleValue(t, p) < 10 {
			t.Errorf("oldest_age_ms should reflect the 20ms-old waiter: %q", p)
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
		{"client gone while queued", store.InferenceRouteOutcome{FinalStatus: finalStatusCancelled, ErrorClass: "client_gone"}, queueClassClientGone},
		{"queue_deadline", store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: rejectionReasonQueueDeadline}, queueClassQueueDeadline},
		{"queue_timeout", store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: "queue_timeout"}, queueClassQueueTimeout},
		{"ttft_too_slow", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "ttft_too_slow"}, queueClassTTFTTooSlow},
		{"tool constraint unavailable", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "model_capability_unsupported"}, queueClassCapabilityUnsupported},
		{"unknown exit class is other", store.InferenceRouteOutcome{FinalStatus: finalStatusError, ErrorClass: "something_new"}, queueClassOther},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := queueOutcomeClass(&tc.outcome); got != tc.want {
				t.Fatalf("queueOutcomeClass = %q, want %q", got, tc.want)
			}
		})
	}
	if got := queueOutcomeClass(nil); got != "" {
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
	srv.SetDatadog(dd)

	const model = "queue-exit-unit-model"
	attemptTotal := func(snap MetricsSnapshot) int64 {
		var total int64
		for key, v := range snap.Counters {
			if strings.HasPrefix(key, metricAttemptOutcomeCounter) && strings.Contains(key, "model="+model) {
				total += v
			}
		}
		return total
	}

	queued := &store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: rejectionReasonQueueDeadline, ErrorCode: http.StatusGatewayTimeout, QueueExit: true}
	srv.emitAttemptOutcomeMetric(model, queued)
	snap := srv.metrics.Snapshot()
	if got := attemptTotal(snap); got != 0 {
		t.Fatalf("attempt_outcome after a queue exit = %d, want 0; counters=%v", got, snap.Counters)
	}
	if got := snap.Counters[counterKey(metricQueueOutcomeCounter,
		MetricLabel{"model", model}, MetricLabel{"class", queueClassQueueDeadline})]; got != 1 {
		t.Fatalf("queue_outcome{queue_deadline} = %d, want 1; counters=%v", got, snap.Counters)
	}

	// A queue exit that never became terminal is not counted anywhere.
	srv.emitAttemptOutcomeMetric(model, &store.InferenceRouteOutcome{QueueExit: true})

	// The same class from a DISPATCHED attempt still counts as an attempt.
	dispatched := &store.InferenceRouteOutcome{FinalStatus: finalStatusTimeout, ErrorClass: rejectionReasonQueueDeadline, ErrorCode: http.StatusGatewayTimeout}
	srv.emitAttemptOutcomeMetric(model, dispatched)
	snap = srv.metrics.Snapshot()
	if got := attemptTotal(snap); got != 1 {
		t.Fatalf("attempt_outcome after a dispatched terminal = %d, want 1; counters=%v", got, snap.Counters)
	}
	if got := snap.Counters[counterKey(metricAttemptOutcomeCounter,
		MetricLabel{"model", model}, MetricLabel{"class", attemptClassCapacity})]; got != 1 {
		t.Fatalf("attempt_outcome{capacity} = %d, want 1; counters=%v", got, snap.Counters)
	}
	var queueTotal int64
	for key, v := range snap.Counters {
		if strings.HasPrefix(key, metricQueueOutcomeCounter) && strings.Contains(key, "model="+model) {
			queueTotal += v
		}
	}
	if queueTotal != 1 {
		t.Fatalf("queue_outcome total = %d, want exactly the one queue exit; counters=%v", queueTotal, snap.Counters)
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, metricQueueOutcome, "model:"+model, "class:"+queueClassQueueDeadline); got != 1 {
		t.Errorf("UDP queue_outcome{queue_deadline} = %v, want 1; packets=%v", got, findMetrics(packets, metricQueueOutcome))
	}
	if got := sumMetric(t, packets, metricAttemptOutcome, "model:"+model); got != 1 {
		t.Errorf("UDP attempt_outcome total = %v, want 1 (the dispatched terminal only); packets=%v", got, findMetrics(packets, metricAttemptOutcome))
	}
}

// TestQueuedExit_LiveQueueDeadline_CountsOnQueueOutcome drives the REAL HTTP
// + WebSocket path: the single slot is saturated, the request queues, and the
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
	srv, _, _, ts := queuedFleetHarnessConfigured(t, ctx, ServerConfig{FirstContentDeadlineBase: 400 * time.Millisecond}, model, func(s *Server) {
		s.SetDatadog(dd)
	})

	res := chatRequestWithID(ctx, ts.URL, model, "queue-exit-live")
	if res.err != nil {
		t.Fatalf("chat request: %v", res.err)
	}
	if res.status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body=%s", res.status, res.body)
	}

	queueKey := counterKey(metricQueueOutcomeCounter, MetricLabel{"model", model}, MetricLabel{"class", queueClassQueueDeadline})
	snap := waitForCounters(t, srv, 3*time.Second, func(s MetricsSnapshot) bool {
		return s.Counters[queueKey] >= 1
	})
	if got := snap.Counters[queueKey]; got != 1 {
		t.Fatalf("queue_outcome{queue_deadline} = %d, want 1; counters=%v", got, snap.Counters)
	}
	for key, v := range snap.Counters {
		if strings.HasPrefix(key, metricAttemptOutcomeCounter) && strings.Contains(key, "model="+model) && v != 0 {
			t.Fatalf("attempt_outcome incremented for a queue-only request: %s=%d; counters=%v", key, v, snap.Counters)
		}
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, metricQueueOutcome, "model:"+model, "class:"+queueClassQueueDeadline); got != 1 {
		t.Errorf("UDP queue_outcome{queue_deadline} = %v, want 1; packets=%v", got, findMetrics(packets, metricQueueOutcome))
	}
	if got := sumMetric(t, packets, metricAttemptOutcome, "model:"+model); got != 0 {
		t.Errorf("UDP attempt_outcome total = %v, want 0 for a queue-only request; packets=%v", got, findMetrics(packets, metricAttemptOutcome))
	}
}
