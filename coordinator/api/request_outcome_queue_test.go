package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/outcomes"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRequestAccountingQueuedDispatchDoesNotInheritPriorError(t *testing.T) {
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
			reg, _, srv, ts := setupTTFTFailoverServer(t)
			t.Cleanup(srv.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			const model = "accounting-queued-dispatch"
			fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
				Name: "queued-provider", Version: "0.8.10", Models: []failoverModelSpec{{ID: model}},
				Script: func(ctx context.Context, _ *failoverProvider, _ protocol.InferenceRequestMessage, _ []byte) {
					<-ctx.Done()
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
			received := time.Now()
			tracker := outcomes.New("queued-accounting", "/v1/chat/completions", received, nil)
			ctx = context.WithValue(ctx, requestMetaKey{}, &requestMeta{coordID: "queued-accounting", start: received, outcome: tracker})
			d := &dispatchState{
				s: srv, r: httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx), w: httptest.NewRecorder(),
				model: model, publicModel: model, rawBody: []byte(`{"model":"accounting-queued-dispatch","messages":[{"role":"user","content":"hello"}],"max_tokens":64}`),
				consumerKey: "test-key", estimatedPromptTokens: 16, requestedMaxTokens: 64,
				deadline: 5 * time.Second, timing: &registry.RequestTiming{ReceivedAt: received},
				excludeProviders: map[string]struct{}{}, refundReservation: func() {},
			}
			if priorOverflow {
				// This is the supported retry-to-queue path: an incompatible
				// provider failed preparation while the compatible one was busy.
				d.attempt = 1
				d.lastErr = errProviderBodyTooLarge.Error()
				d.lastErrCode = http.StatusRequestEntityTooLarge
				d.providerBodyTooLargeErr = d.lastErr
			}
			previousError, previousStatus := d.lastErr, d.lastErrCode
			result := make(chan dispatchOutcome, 1)
			go func() { result <- d.dispatchPrimary() }()
			waitForAdaptiveCondition(t, time.Second, func() bool { return reg.Queue().QueueSize(model) == 1 })
			capacity(0)
			select {
			case got := <-result:
				if got != outcomeProceed {
					t.Fatalf("dispatch outcome=%v error=%q code=%d", got, d.lastErr, d.lastErrCode)
				}
			case <-ctx.Done():
				t.Fatal("queued dispatch did not finish")
			}
			row := tracker.Snapshot()
			var dispatched *outcomes.AttemptRecord
			for i := range row.Attempts {
				if row.Attempts[i].RequestID == d.pr.RequestID {
					dispatched = &row.Attempts[i]
				}
			}
			if dispatched == nil || !dispatched.WriteStarted || !dispatched.WriteCompleted || row.DispatchedAttemptCount != 1 {
				t.Fatalf("missing queued write evidence: %+v", row)
			}
			if dispatched.RawReason != "" || dispatched.HTTPStatus != nil || dispatched.ProviderOutcome != "no_terminal" {
				t.Fatalf("successful queued dispatch inherited an error: %+v", *dispatched)
			}
			if d.lastErr != previousError || d.lastErrCode != previousStatus {
				t.Fatalf("accounting changed routing history: error=%q status=%d", d.lastErr, d.lastErrCode)
			}
		})
	}
}

func TestRequestAccountingQueuedDeadlineKeepsAttemptReason(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "accounting-queue-deadline-reason"
	srv, st, _, ts := queuedFleetHarness(t, ctx, ServerConfig{FirstContentDeadlineBase: 300 * time.Millisecond}, model)
	t.Cleanup(srv.Close)
	response := chatRequestWithID(ctx, ts.URL, model, "queued-deadline")
	if response.err != nil || response.status != http.StatusTooManyRequests {
		t.Fatalf("queue deadline response: %+v", response)
	}
	row := waitRequestOutcome(t, st, 1)[0]
	queued := row.Attempts[len(row.Attempts)-1]
	if row.RawReason != rejectionReasonQueueDeadline || row.DispatchedAttemptCount != 0 || queued.WriteStarted || queued.WriteCompleted || queued.ProviderOutcome != "not_dispatched" {
		t.Fatalf("queue deadline dispatch evidence: %+v", row)
	}
	if queued.RawReason != rejectionReasonQueueDeadline || queued.HTTPStatus == nil || *queued.HTTPStatus != http.StatusGatewayTimeout {
		t.Fatalf("queue attempt lost its own terminal diagnostic: %+v", queued)
	}
}

func TestRequestAccountingQueuedWriteFailureKeepsAttemptReason(t *testing.T) {
	s := newTestServerForDispatch(t)
	s.registry.SetQueue(registry.NewRequestQueue(4, 5*time.Second))
	const model = "accounting-queue-write-failure"
	tracker := outcomes.New("queued-write-failure", "/v1/completions", time.Now(), nil)
	ctx := context.WithValue(context.Background(), requestMetaKey{}, &requestMeta{outcome: tracker})
	d := queueDispatchState(s, model, nil, httptest.NewRequest(http.MethodPost, "/v1/completions", nil).WithContext(ctx), 5*time.Second)
	d.lastErr, d.lastErrCode = "prior provider error", http.StatusBadGateway
	result := make(chan dispatchOutcome, 1)
	go func() { result <- d.dispatchPrimary() }()
	waitForAdaptiveCondition(t, time.Second, func() bool { return s.registry.Queue().QueueSize(model) == 1 })
	makeRoutableProvider(t, s.registry, "accounting-write-failure-provider", model) // nil socket fails the actual writer
	s.registry.DrainQueuedRequestsForModel(model)
	select {
	case got := <-result:
		if got != outcomeRetry {
			t.Fatalf("write failure outcome=%v, want retry", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("queued write failure did not return")
	}
	row := tracker.Snapshot()
	queued := row.Attempts[len(row.Attempts)-1]
	if row.DispatchedAttemptCount != 0 || queued.WriteCompleted || queued.RawReason != "provider_error" || queued.HTTPStatus != nil {
		t.Fatalf("queued write failure lost its own diagnostic: %+v", queued)
	}
	if d.lastErr != "failed to send request to provider" || d.lastErrCode != 0 {
		t.Fatalf("write failure changed routing behavior: %q/%d", d.lastErr, d.lastErrCode)
	}
}
