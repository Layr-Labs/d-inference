package inference

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPredictiveProfileKeepsPolicySeparateFromBypass(t *testing.T) {
	srv := newProfilerTestServer(t)
	for _, tc := range []struct {
		name   string
		hard   bool
		policy selfRoutePolicy
		vision bool
		mode   string
		bypass string
	}{
		{"soft", false, selfRoutePolicy{}, false, "soft", "none"},
		{"hard", true, selfRoutePolicy{}, false, "hard", "none"},
		{"media", true, selfRoutePolicy{}, true, "hard", "media"},
		{"self", true, selfRoutePolicy{enabled: true}, false, "hard", "self_route"},
		{"prefer", true, selfRoutePolicy{prefer: true}, false, "hard", "prefer_owner"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv.SetTTFTHardReject(tc.hard)
			rp := observedTestProfile(t, srv, time.Now(), "coord-"+tc.name)
			ap := rp.NewAttempt("attempt-"+tc.name, 0, "")
			srv.recordPredictivePolicy(ap, tc.policy, tc.vision)
			ap.CompleteTerminal()
			ap.CompleteHandler()
			rec := awaitPersistedProfile(t, srv, ap)
			if rec.AdmissionMode != tc.mode || rec.PredictiveBypass != tc.bypass {
				t.Fatalf("policy=%q bypass=%q", rec.AdmissionMode, rec.PredictiveBypass)
			}
			if rec.ReservationTTFTCeilingMs != nil || rec.DispatchBudgetMs != nil {
				t.Fatal("unobserved reservation/writer values must remain absent")
			}
		})
	}
}

func TestPredictiveProfileCapturesActualWriterEnvelopePerAttempt(t *testing.T) {
	srv := newProfilerTestServer(t)
	t0 := time.Now()
	rp := observedTestProfile(t, srv, t0, "coord")
	for i, requestID := range []string{"primary", "backup", "retry"} {
		backupOf := ""
		attempt := i
		if i == 1 {
			backupOf, attempt = "primary", 0
		}
		ap := rp.NewAttempt(requestID, attempt, backupOf)
		srv.recordPredictivePolicy(ap, selfRoutePolicy{}, false)
		ap.SetReservationTTFTCeiling(0)
		pr := &registry.PendingRequest{Profile: ap, FirstContentDeadline: t0.Add(time.Second)}
		builder := providerInferenceFrameBuilder(requestID, "key", "body", pr)
		// Dispatch cleanup may change the pending object after enqueue. The
		// writer must use its captured profile and deadline, never reread it.
		pr.Profile = nil
		pr.FirstContentDeadline = time.Time{}
		data, err := builder(t0.Add(time.Duration(i+1) * 100 * time.Millisecond))
		if err != nil {
			t.Fatal(err)
		}
		var wire protocol.InferenceRequestMessage
		if err := json.Unmarshal(data, &wire); err != nil {
			t.Fatal(err)
		}
		ap.CompleteTerminal()
		ap.CompleteHandler()
		rec := awaitPersistedProfile(t, srv, ap)
		if rec.DispatchBudgetMs == nil || *rec.DispatchBudgetMs != wire.FirstContentBudgetMS || *rec.DispatchBudgetMs != int64(900-i*100) {
			t.Fatalf("recorded=%v wire=%d", rec.DispatchBudgetMs, wire.FirstContentBudgetMS)
		}
		if rec.ReservationTTFTCeilingMs == nil || *rec.ReservationTTFTCeilingMs != 0 || rec.RequestID != requestID || rec.BackupOf != backupOf || rec.Attempt != attempt {
			t.Fatalf("attempt context changed: %+v", rec)
		}
		if rec.WriteDoneUS != nil || rec.AcceptedUS != nil {
			t.Fatal("envelope construction must not claim delivery or acceptance")
		}
	}
	for i, deadline := range []time.Time{t0, {}} {
		id := fmt.Sprintf("unsent-%d", i)
		ap := rp.NewAttempt(id, 2+i, "")
		builder := providerInferenceFrameBuilder(id, "key", "body", &registry.PendingRequest{Profile: ap, FirstContentDeadline: deadline})
		_, _ = builder(t0)
		ap.CompleteTerminal()
		ap.CompleteHandler()
		if rec := awaitPersistedProfile(t, srv, ap); rec.DispatchBudgetMs != nil {
			t.Fatal("expired or absent deadline must not invent an encoded positive budget")
		}
	}
}
