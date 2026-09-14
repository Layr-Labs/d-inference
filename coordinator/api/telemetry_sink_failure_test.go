package api

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"testing"
	"time"
)

// TestServerCloseFlushesRouteTelemetryBeforeReturning covers the production
// shutdown path: Server.Close waits (bounded) for the sink's final drain, so
// rows are in the store when Close returns — before main closes the pool —
// and anything submitted afterwards is rejected and counted.
func TestServerCloseFlushesRouteTelemetryBeforeReturning(t *testing.T) {
	srv, st := testServer(t)
	srv.submitRouteRecord(routeRec("shut-1", 1, "p"))
	srv.updateInferenceRouteOutcomeWithModel("shut-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: 2, CompletionTokensSet: true})

	srv.Close()

	var found *store.InferenceRouteRecord
	for _, r := range st.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == "shut-1" {
			rec := r
			found = &rec
		}
	}
	if found == nil || found.FinalStatus != "success" || found.CompletionTokens != 2 {
		t.Fatalf("Close must flush the buffered route record and its outcome before returning: %+v", found)
	}

	srv.submitRouteRecord(routeRec("shut-2", 1, "p"))
	if got := srv.routeTelemetry.DroppedTotal(); got != 1 {
		t.Fatalf("post-Close submit must be rejected and counted: dropped=%d", got)
	}
	for _, r := range st.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == "shut-2" {
			t.Fatal("post-Close submit must not be persisted")
		}
	}
}
