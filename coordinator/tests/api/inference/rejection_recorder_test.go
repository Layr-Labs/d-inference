package inference_test

import (
	"net/http"
	"strings"
	"testing"

	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
	srv.observation.SetDatadog(dd)

	const model = "or-view-mirror-model"
	srv.NewRejectionRecorder().Record(nil, &store.RejectionRecord{
		Stage: "preflight_capacity", ReasonCode: "machine_busy", HTTPStatus: http.StatusTooManyRequests,
		RequestedModel: "client-typed-alias", ResolvedModel: model, RetryAfterMs: 7000,
	}, rejection.Servability{})
	srv.NewRejectionRecorder().Record(nil, &store.RejectionRecord{
		Stage: "validation", ReasonCode: "bad_request", HTTPStatus: http.StatusBadRequest,
		RequestedModel: "client-typed-alias", ResolvedModel: model,
	}, rejection.Servability{})

	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := sumMetric(t, packets, infermetrics.ORViewMetric, "model:"+model, "class:"+infermetrics.ORRateLimited); got != 1 {
		t.Errorf("request_outcome_or_view{rate_limited} = %v, want 1; packets=%v", got, findMetrics(packets, infermetrics.ORViewMetric))
	}
	if got := sumMetric(t, packets, infermetrics.ORViewMetric, "model:"+model, "class:"+infermetrics.ORClientError); got != 1 {
		t.Errorf("request_outcome_or_view{client_error} = %v, want 1; packets=%v", got, findMetrics(packets, infermetrics.ORViewMetric))
	}
	for _, p := range findMetrics(packets, infermetrics.ORViewMetric) {
		if strings.Contains(p, "client-typed-alias") {
			t.Errorf("request_outcome_or_view must tag the RESOLVED model only: %q", p)
		}
	}
}
