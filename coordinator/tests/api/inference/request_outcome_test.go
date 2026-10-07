package inference_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	inference "github.com/eigeninference/d-inference/coordinator/api/inference"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRequestOutcomeQueueAndMissingTerminal(t *testing.T) {
	for _, kind := range []string{"queue_full", "queue_deadline"} {
		t.Run(kind, func(t *testing.T) {
			srv := newTestServerForDispatch(t)
			defer srv.Close()
			size := 1
			if kind == "queue_full" {
				size = 0
			}
			srv.registry.SetQueue(registry.NewRequestQueue(size, time.Second))
			srv.observation.ObserveRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				rp := srv.observation.NewRequestProfile(r, "queued-model", "queued-model", false)
				r = r.WithContext(access.WithConsumer(r.Context(), "public-queue-consumer"))
				observation.MarkPublicModelDemand(r, false, true, nil, "", "queued-model")
				session := srv.NewDispatchSession(inference.DispatchRequest{
					Writer: w, Request: r, Model: "queued-model", PublicModel: "queued-model",
					Body:             []byte(`{"model":"queued-model","messages":[]}`),
					Scope:            dispatch.Scope{PreferOwner: true, OwnerAccountID: testConsumerID},
					ConsumerEndpoint: inreq.CompletionsEndpoint, Timing: &registry.RequestTiming{ReceivedAt: time.Now()},
					Deadline: 50 * time.Millisecond, SpeculativeAt: 25 * time.Millisecond,
					RefundReservation: func() {}, RequestedMaxTokens: 16, EstimatedPromptTokens: 1,
					Traits: registry.RequestTraits{ParallelToolCalls: true}, RequestedStopSequences: []string{"stop"}, Profile: rp,
				})
				session.Run(r.Context())
			})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/completions", nil))
			r := awaitRequestOutcomes(t, srv.store, 1)[0]
			for _, a := range r.Attempts {
				if a.WriteCompleted && kind != "terminal_grace" {
					t.Fatalf("queue falsely dispatched %+v", r)
				}
			}
			if kind == "terminal_grace" {
				if r.Termination != "unknown" || r.EgressCompleted || r.Attempts[0].ProviderOutcome != "no_terminal" {
					t.Fatalf("grace fabricated result %+v", r)
				}
			} else {
				if r.Termination != "rejected" || r.RawReason != kind || r.NormalizedCode == "ext_first_content_timeout" {
					t.Fatalf("queue conflated with first-content timeout %+v", r)
				}
				if r.PublicDemand != nil {
					t.Fatalf("owner-directed queue created public demand: %+v", r.PublicDemand)
				}
			}
		})
	}
}
