package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRequestOutcomeQueuedDispatchDoesNotInheritPriorError(t *testing.T) {
	t.Setenv(envProfiler, "off")
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")
	for _, priorOverflow := range []bool{false, true} {
		name := "first attempt"
		if priorOverflow {
			name = "retry after incompatible provider"
		}
		t.Run(name, func(t *testing.T) {
			reg, st, srv, ts := setupTTFTFailoverServer(t)
			t.Cleanup(srv.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			const model = "accounting-queued-dispatch"
			fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
				Name: "queued-provider", Version: "0.8.10", Models: []failoverModelSpec{{ID: model}},
			})
			p := reg.GetProvider(fp.registryID)
			var pr *registry.PendingRequest
			srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				rp := srv.newRequestProfile(r, model, model, false)
				index := 0
				if priorOverflow {
					index = 1
					prior := rp.NewAttempt("incompatible-provider", 0, "")
					prior.SetOutcome("error", "client_error", "", "not_dispatched", "error_response")
					prior.CompleteTerminal()
					prior.CompleteHandler()
				}
				// The dispatch owner's real queue/writer fixture proves these
				// producer facts and unchanged routing history. Here they enter
				// the actual compact-record and provider-terminal API boundary.
				ap := rp.NewAttempt("queued-write", index, "")
				ap.ProviderID = p.ID
				ap.Mark(registry.StampQueued)
				ap.Mark(registry.StampDequeued)
				ap.Mark(registry.StampWriteSubmitted)
				ap.Mark(registry.StampWriteDone)
				pr = &registry.PendingRequest{
					RequestID: ap.RequestID, Attempt: index, Model: model, PublicModel: model, ProviderID: p.ID,
					ConsumerKey: "test-key", Profile: ap, EstimatedPromptTokens: 16, RequestedMaxTokens: 64,
					FirstContentDeadline: time.Now().Add(5 * time.Second),
					Timing:               &registry.RequestTiming{ReceivedAt: rp.T0, DispatchedAt: time.Now()},
					ChunkCh:              make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
				}
				p.AddPending(pr)
				ap.SetOutcome("", "", "", "", "error_response")
				ap.CompleteHandler()
			})(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx))
			// Read the ordinary handler-finished revision from the sink/store
			// before letting the real provider terminal enrich the same record.
			var row store.RequestOutcomeRecord
			waitForAdaptiveCondition(t, time.Second, func() bool {
				rows, err := st.RequestOutcomes(ctx, time.Time{}, time.Now().Add(time.Second), 10)
				if err != nil {
					t.Fatal(err)
				}
				if len(rows) != 1 || rows[0].HandlerFinishedAt == nil {
					return false
				}
				row = rows[0]
				return true
			})
			var dispatched *store.RequestAttemptOutcome
			dispatchedCount := 0
			for i := range row.Attempts {
				if row.Attempts[i].WriteCompleted {
					dispatchedCount++
				}
				if row.Attempts[i].RequestID == pr.RequestID {
					dispatched = &row.Attempts[i]
				}
			}
			if dispatched == nil || !dispatched.WriteSubmitted || !dispatched.WriteCompleted || dispatchedCount != 1 {
				t.Fatalf("missing queued write evidence: %+v", row)
			}
			if dispatched.RawReason != "" || dispatched.FinalStatus != "" || dispatched.ProviderOutcome != "no_terminal" {
				t.Fatalf("successful queued dispatch inherited an error: %+v", *dispatched)
			}
			// The terminal still arrives over the real registered provider socket.
			fp.sendComplete(ctx, protocol.InferenceRequestMessage{RequestID: pr.RequestID}, protocol.UsageInfo{PromptTokens: 5})
			final := awaitRequestOutcomes(t, st, 1)[0]
			for _, attempt := range final.Attempts {
				if attempt.RequestID == pr.RequestID && (attempt.ProviderOutcome != "completed" || attempt.RawReason != "" || attempt.FinalStatus != "success") {
					t.Fatalf("late provider success inherited previous error: %+v", final)
				}
			}
		})
	}
}
