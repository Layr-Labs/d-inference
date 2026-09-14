package api

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"testing"
	"time"
)

// TestServerRouteTelemetryWithoutSinkFallsBackToGoroutine covers a Server
// built directly (no NewServer, no sink): writes still land, one goroutine
// per write as before.
func TestServerRouteTelemetryWithoutSinkFallsBackToGoroutine(t *testing.T) {
	st := store.NewMemory(store.Config{})
	s := &Server{store: st, logger: quietLogger()}

	s.submitRouteRecord(routeRec("ns-1", 1, "p"))
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(st.InferenceRouteRecordsSince(time.Time{})) == 1 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	s.submitRouteOutcome("ns-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"})
	for time.Now().Before(deadline) {
		recs := st.InferenceRouteRecordsSince(time.Time{})
		if len(recs) == 1 && recs[0].FinalStatus == "success" {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("fallback path did not persist: %+v", st.InferenceRouteRecordsSince(time.Time{}))
}

// TestServerRouteTelemetryThroughSink wires the production path: NewServer's
// sink, the dispatch-side record helper, and the outcome funnel every
// terminal uses (updateInferenceRouteOutcomeWithModel).
func TestServerRouteTelemetryThroughSink(t *testing.T) {
	srv, st := testServer(t)
	if srv.routeTelemetry == nil {
		t.Fatal("NewServer must install the telemetry sink")
	}

	srv.submitRouteRecord(routeRec("ts-1", 1, "p"))
	srv.updateInferenceRouteOutcomeWithModel("ts-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: 4, CompletionTokensSet: true})

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, r := range st.InferenceRouteRecordsSince(time.Time{}) {
			if r.RequestID == "ts-1" && r.FinalStatus == "success" && r.CompletionTokens == 4 {
				return
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("sink path did not persist within the window: %+v", st.InferenceRouteRecordsSince(time.Time{}))
}
