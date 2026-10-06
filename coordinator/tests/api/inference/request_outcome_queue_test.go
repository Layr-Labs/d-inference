package inference_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/profile"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
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
			complete := make(chan struct{})
			fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
				Name: "queued-provider", Version: "0.8.10", Models: []failoverModelSpec{{ID: model}},
				Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
					select {
					case <-complete:
						fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 5})
					case <-ctx.Done():
					}
				},
			})
			p := reg.GetProvider(fp.registryID)
			capacity := func(used int64) {
				writeAdaptiveHeartbeat(t, ctx, fp.conn, model, &protocol.BackendCapacity{
					TotalMemoryGB: 64,
					Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "running", MaxConcurrency: 1, ActiveTokenBudgetUsed: used, ActiveTokenBudgetMax: 1000}},
				})
			}
			capacity(950)
			waitForAdaptiveCondition(t, time.Second, func() bool {
				p.Mu().Lock()
				defer p.Mu().Unlock()
				return p.BackendCapacity != nil && p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 950
			})
			var result inference.PrimaryResult
			var previousError string
			var previousStatus int
			srv.observation.ObserveRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				received := time.Now()
				request := inference.PrimaryRequest{
					Dispatch: providerdispatch.Input{
						Request: r, Scope: providerdispatch.Scope{PreferOwner: true, OwnerAccountID: testConsumerID},
						Model: model, PublicModel: model, Body: []byte(`{"model":"accounting-queued-dispatch","messages":[{"role":"user","content":"hello"}],"max_tokens":64}`),
						ConsumerKey: "test-key", EstimatedPromptTokens: 16, RequestedMaxTokens: 64,
						Deadline: 5 * time.Second, Timing: &registry.RequestTiming{ReceivedAt: received},
						Exclusions: providerdispatch.NewExclusions(),
					},
					Writer: w, Refund: func() {},
				}
				request.Dispatch.Profile = srv.observation.NewRequestProfile(r, model, model, false)
				defer profile.Finalize(request.Dispatch.Profile, r, false)
				if priorOverflow {
					// This is the supported retry-to-queue path: an incompatible
					// provider failed preparation while the compatible one was busy.
					request.Dispatch.Attempt = 1
					request.History.Failure = retry.CoordinatorFailure(providerwire.ErrBodyTooLarge.Error(), http.StatusRequestEntityTooLarge)
					request.History.Overflow.Message = request.History.Failure.Message.Error
				}
				previousError, previousStatus = request.History.Failure.Message.Error, request.History.Failure.Message.StatusCode
				primary := srv.NewPrimary(inference.PrimaryResources{})
				outcome := make(chan inference.PrimaryResult, 1)
				go func() { outcome <- primary.Run(request) }()
				waitForAdaptiveCondition(t, time.Second, func() bool { return reg.Queue().QueueSize(model) == 1 })
				capacity(0)
				select {
				case result = <-outcome:
					if got := result.Outcome; got != attempt.Proceed {
						t.Fatalf("dispatch outcome=%v error=%q code=%d", got, result.History.Failure.Message.Error, result.History.Failure.Message.StatusCode)
					}
				case <-ctx.Done():
					t.Fatal("queued dispatch did not finish")
				}
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
				if row.Attempts[i].RequestID == result.Pending.RequestID {
					dispatched = &row.Attempts[i]
				}
			}
			if dispatched == nil || !dispatched.WriteSubmitted || !dispatched.WriteCompleted || dispatchedCount != 1 {
				t.Fatalf("missing queued write evidence: %+v", row)
			}
			if dispatched.RawReason != "" || dispatched.FinalStatus != "" || dispatched.ProviderOutcome != "no_terminal" {
				t.Fatalf("successful queued dispatch inherited an error: %+v", *dispatched)
			}
			if result.History.Failure.Message.Error != previousError || result.History.Failure.Message.StatusCode != previousStatus {
				t.Fatalf("accounting changed routing history: error=%q status=%d", result.History.Failure.Message.Error, result.History.Failure.Message.StatusCode)
			}
			close(complete)
			final := awaitRequestOutcomes(t, st, 1)[0]
			for _, attempt := range final.Attempts {
				if attempt.RequestID == result.Pending.RequestID && (attempt.ProviderOutcome != "completed" || attempt.RawReason != "" || attempt.FinalStatus != "success") {
					t.Fatalf("late provider success inherited previous error: %+v", final)
				}
			}
		})
	}
}
