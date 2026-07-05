package api

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// reserveForCalibration reserves a warm provider through the real scheduler
// (which registers the raw TTFT prediction with the calibrator) and returns a
// pending request whose Timing carries a dispatch stamp in the past, as the
// commit path would see it.
func reserveForCalibration(t *testing.T, srv *Server, model, requestID string) *registry.PendingRequest {
	t.Helper()
	pr := &registry.PendingRequest{
		RequestID:             requestID,
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    128,
		Timing:                &registry.RequestTiming{DispatchedAt: time.Now().Add(-900 * time.Millisecond)},
	}
	p, decision := srv.registry.ReserveProviderEx(model, pr)
	if p == nil {
		t.Fatalf("reserve failed for %s: %+v", requestID, decision)
	}
	p.RemovePending(requestID)
	srv.registry.SetProviderIdle(p.ID)
	return pr
}

// observeTTFTCalibration must join the committed attempt's measured
// first-content latency to the scheduler-recorded prediction — and must skip
// speculative-race attempts and incomplete timings.
func TestObserveTTFTCalibrationFeedsRegistry(t *testing.T) {
	registry.ResetTTFTCalibration()
	t.Cleanup(registry.ResetTTFTCalibration)

	srv, _ := testServer(t)
	model := "ttft-calib-hook-model"
	registerBuildsProvider(srv, "calib-hook-p1", model)

	// Committed attempt: the hook consumes the pending prediction.
	pr := reserveForCalibration(t, srv, model, "calib-hook-committed")
	pr.MarkFirstContentArrived()
	srv.observeTTFTCalibration(pr)
	if _, ok := registry.RecordTTFTObservation(pr.RequestID, pr.Attempt, 900); ok {
		t.Fatal("prediction still pending — hook did not record the observation")
	}

	// Speculative-race attempt: excluded, prediction left untouched.
	backup := reserveForCalibration(t, srv, model, "calib-hook-backup")
	backup.UsedBackup = true
	backup.MarkFirstContentArrived()
	srv.observeTTFTCalibration(backup)
	if _, ok := registry.RecordTTFTObservation(backup.RequestID, backup.Attempt, 900); !ok {
		t.Fatal("speculative attempt was observed — UsedBackup filter broken")
	}

	// No first content (cancel/error before content): no observation.
	noContent := reserveForCalibration(t, srv, model, "calib-hook-nocontent")
	srv.observeTTFTCalibration(noContent)
	if _, ok := registry.RecordTTFTObservation(noContent.RequestID, noContent.Attempt, 900); !ok {
		t.Fatal("no-content attempt was observed — FirstContentAt filter broken")
	}

	// Degenerate inputs must be safe no-ops.
	srv.observeTTFTCalibration(nil)
	srv.observeTTFTCalibration(&registry.PendingRequest{RequestID: "no-timing"})
}

// Enough committed observations through the hook move the registry's learned
// ratio for the model — the end-to-end loop the calibrator exists for.
func TestObserveTTFTCalibrationConvergesRatio(t *testing.T) {
	registry.ResetTTFTCalibration()
	t.Cleanup(registry.ResetTTFTCalibration)

	srv, _ := testServer(t)
	model := "ttft-calib-loop-model"
	registerBuildsProvider(srv, "calib-loop-p1", model)

	for i := 0; i < 60; i++ {
		pr := reserveForCalibration(t, srv, model, fmt.Sprintf("calib-loop-%d", i))
		pr.MarkFirstContentArrived()
		srv.observeTTFTCalibration(pr)
	}
	ratio := registry.TTFTCalibrationRatio(model, "")
	if ratio == 1.0 {
		t.Fatal("learned ratio still 1.0 after 60 hook observations")
	}
	if ratio <= 0 || ratio > 1.5 {
		t.Fatalf("learned ratio %f outside the applied clamp band", ratio)
	}
}
