package inference_test

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// waitForDeadlineTelemetryWhere waits for the row counts AND, when given, for
// the route rows to satisfy settled. The route sink writes the attempt record
// and its outcome as separate batched statements, so a row can be visible
// before its final_status/error_reason are; callers that assert on outcome
// fields must wait for them explicitly.

func TestDeadlineUnreachableFailoverCarriesDecreasingBudgets(t *testing.T) {
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD", "1")
	reg, st, srv, ts := setupTTFTFailoverServer(t)
	srv.SetTTFTHardReject(true)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "deadline-failover-model"
	recorder := &deadlineAttemptRecorder{}
	script := func(
		ctx context.Context,
		fp *failoverProvider,
		req protocol.InferenceRequestMessage,
		_ []byte,
	) {
		if recorder.capture(t, reg, fp, req) == 1 {
			// Make the second attempt's remaining wire and hard-admission
			// budgets observably smaller than the first attempt's.
			time.Sleep(100 * time.Millisecond)
			fp.sendTypedInferenceError(
				ctx,
				req,
				protocol.FailureCodeCapacity,
				failure.ErrorReasonDeadlineUnreachable,
				http.StatusServiceUnavailable,
			)
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}

	providers := []*failoverProvider{
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: "provider-a", Version: "0.8.10", DecodeTPS: 200,
			Models: []failoverModelSpec{{ID: model}}, Script: script,
		}),
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: "provider-b", Version: "0.8.10", DecodeTPS: 100,
			Models: []failoverModelSpec{{ID: model}}, Script: script,
		}),
	}

	status, body, err := postChat(
		ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	attempts := recorder.snapshot()
	if len(attempts) != 2 || attempts[0].provider == attempts[1].provider {
		t.Fatalf(
			"attempts = %+v, want one deadline refusal then a distinct winner; status=%d body=%s",
			attempts, status, body)
	}
	assertAttemptBudgetsDecrease(t, attempts)
	assertCleanFailoverStream(t, status, body, markerFor(attempts[1].provider))
	outcome := awaitRequestOutcomes(t, st, 1)[0]
	declined, dispatched := 0, 0
	for _, a := range outcome.Attempts {
		if a.WriteCompleted {
			dispatched++
		}
		if a.NormalizedCode == "int_provider_deadline_rejected" {
			declined++
		}
	}
	if outcome.Termination != "completed" || outcome.NormalizedCode != "" || declined != 1 || dispatched != 2 {
		t.Fatalf("recovered request accounting: %+v", outcome)
	}

	byName := map[string]*failoverProvider{
		providers[0].name: providers[0],
		providers[1].name: providers[1],
	}
	assertDeadlineRefusalDidNotFeedCapacity(
		t, reg, byName[attempts[0].provider], model)

	routes, _ := waitForDeadlineTelemetryWhere(t, st, 2, 0, func(routes []store.InferenceRouteRecord) bool {
		for _, route := range routes {
			if route.ErrorReason == failure.ErrorReasonDeadlineUnreachable {
				return true
			}
		}
		return false
	})
	deadlineRoutes := 0
	for _, route := range routes {
		if route.ErrorReason != failure.ErrorReasonDeadlineUnreachable {
			continue
		}
		deadlineRoutes++
		if route.ErrorClass != routeoutcome.ErrorClassDeadlineUnreachable {
			t.Errorf("deadline route class = %q, want %q", route.ErrorClass, routeoutcome.ErrorClassDeadlineUnreachable)
		}
		if route.AdmittedButFailed {
			t.Error("pre-content deadline refusal must not be admitted-but-failed")
		}
	}
	if deadlineRoutes != 1 {
		t.Errorf("deadline route rows = %d, want 1; routes=%+v", deadlineRoutes, routes)
	}
}

func TestDeadlineUnreachableStopsAfterTwoWithoutFreshEvidence(t *testing.T) {
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD", "1")
	reg, st, srv, ts := setupTTFTFailoverServer(t)
	srv.SetTTFTHardReject(true)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "deadline-exhausted-model"
	recorder := &deadlineAttemptRecorder{}
	script := func(
		ctx context.Context,
		fp *failoverProvider,
		req protocol.InferenceRequestMessage,
		_ []byte,
	) {
		recorder.capture(t, reg, fp, req)
		time.Sleep(40 * time.Millisecond)
		fp.sendTypedInferenceError(
			ctx,
			req,
			protocol.FailureCodeCapacity,
			failure.ErrorReasonDeadlineUnreachable,
			http.StatusServiceUnavailable,
		)
	}

	providerCount := maxCapacityClassRetries + 1
	providers := make([]*failoverProvider, 0, providerCount)
	for i := 0; i < providerCount; i++ {
		providers = append(providers, startFailoverProvider(
			t, ctx, ts, reg, failoverProviderConfig{
				Name: fmt.Sprintf("provider-%d", i), Version: "0.8.10",
				DecodeTPS: 200 - float64(i),
				Models:    []failoverModelSpec{{ID: model}},
				Script:    script,
			}))
	}

	status, body, err := postChat(
		ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body=%s", status, body)
	}
	if !strings.Contains(body, "rate_limit_exceeded") ||
		!strings.Contains(body, "remaining deadline") {
		t.Errorf("deadline 429 body lost retryable deadline semantics: %s", body)
	}
	if strings.Contains(body, rejectionReasonOversized) {
		t.Errorf("deadline refusal was mislabeled oversized_request: %s", body)
	}

	attempts := recorder.snapshot()
	if len(attempts) != predictiveRefusalRefreshThreshold {
		t.Fatalf("dispatches = %d, want two refusals followed by a fresh-evidence requirement: %+v", len(attempts), attempts)
	}
	assertAttemptBudgetsDecrease(t, attempts)
	for _, provider := range providers {
		assertDeadlineRefusalDidNotFeedCapacity(t, reg, provider, model)
	}

	routes, rejections := waitForDeadlineTelemetry(
		t, st, predictiveRefusalRefreshThreshold, 1)
	if len(rejections) != 1 {
		t.Fatalf("rejection rows = %d, want exactly 1: %+v", len(rejections), rejections)
	}
	if got := rejections[0].ReasonCode; got != rejectionReasonDeadlineUnreachable {
		t.Fatalf(
			"rejection reason = %q, want %q (not oversized_request)",
			got, rejectionReasonDeadlineUnreachable)
	}
	if rejections[0].HTTPStatus != http.StatusTooManyRequests {
		t.Fatalf("rejection status = %d, want 429", rejections[0].HTTPStatus)
	}

	deadlineRoutes := 0
	for _, route := range routes {
		if route.ErrorReason == failure.ErrorReasonDeadlineUnreachable {
			deadlineRoutes++
		}
	}
	if deadlineRoutes != predictiveRefusalRefreshThreshold {
		t.Errorf(
			"deadline route rows = %d, want %d; routes=%+v",
			deadlineRoutes, predictiveRefusalRefreshThreshold, routes)
	}
	outcome := awaitRequestOutcomes(t, st, 1)[0]
	if outcome.Termination != "rejected" || outcome.NormalizedCode != "ext_coordinator_exhausted" {
		t.Fatalf("deadline exhaustion accounting: %+v", outcome)
	}

}

func TestDeadlineRefusalDoesNotMaskLaterProvider500(t *testing.T) {
	reg, st, _, ts := setupTTFTFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const model = "deadline-then-provider-fault"
	var attempts deadlineAttemptRecorder
	script := func(
		ctx context.Context,
		fp *failoverProvider,
		req protocol.InferenceRequestMessage,
		_ []byte,
	) {
		if attempts.capture(t, reg, fp, req) == 1 {
			fp.sendTypedInferenceError(
				ctx, req, protocol.FailureCodeCapacity,
				failure.ErrorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
			return
		}
		fp.sendInferenceError(
			ctx, req, "provider kernel failure", http.StatusInternalServerError)
	}
	for i := 0; i < 2; i++ {
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: fmt.Sprintf("mixed-provider-%d", i), Version: "0.8.10",
			DecodeTPS: 200 - float64(i),
			Models:    []failoverModelSpec{{ID: model}},
			Script:    script,
		})
	}

	status, body, err := postChat(
		ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusInternalServerError {
		t.Fatalf("status=%d body=%s, want later provider 500", status, body)
	}
	if strings.Contains(body, "remaining deadline") {
		t.Fatalf("stale deadline refusal masked provider fault: %s", body)
	}
	_, rejections := waitForDeadlineTelemetry(t, st, 2, 1)
	if len(rejections) != 1 ||
		rejections[0].ReasonCode == rejectionReasonDeadlineUnreachable {
		t.Fatalf("terminal rejection = %+v, want genuine provider fault", rejections)
	}
	outcome := awaitRequestOutcomes(t, st, 1)[0]
	if outcome.Termination != "rejected" || outcome.HTTPStatus != 500 || outcome.NormalizedCode != "ext_legacy:dispatch_exhausted" {
		t.Fatalf("genuine-fault precedence: %+v", outcome)
	}

}

func TestNinthBoilerplateNeverCommitsFailedProvider(t *testing.T) {
	reg, _, _, ts := setupTTFTFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const model = "bounded-boilerplate"
	var attempts deadlineAttemptRecorder
	script := func(
		ctx context.Context,
		fp *failoverProvider,
		req protocol.InferenceRequestMessage,
		_ []byte,
	) {
		if attempts.capture(t, reg, fp, req) == 1 {
			for i := 0; i < maxHeldBoilerplate+1; i++ {
				fp.sendRoleChunk(ctx, req, model)
			}
			fp.sendInferenceError(
				ctx, req, "provider failed after boilerplate",
				http.StatusInternalServerError)
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
	for i := 0; i < 2; i++ {
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: fmt.Sprintf("boilerplate-provider-%d", i), Version: "0.8.10",
			DecodeTPS: 200 - float64(i),
			Models:    []failoverModelSpec{{ID: model}},
			Script:    script,
		})
	}

	status, body, err := postChat(
		ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatal(err)
	}
	got := attempts.snapshot()
	if len(got) != 2 {
		t.Fatalf("attempts=%+v, ninth boilerplate incorrectly committed", got)
	}
	assertCleanFailoverStream(t, status, body, markerFor(got[1].provider))
}

func TestGenericEndpointsShareDeadlineFailover(t *testing.T) {
	cases := []struct {
		name     string
		endpoint string
		body     func(string) string
	}{
		{
			name:     "completions",
			endpoint: "/v1/completions",
			body: func(model string) string {
				return fmt.Sprintf(
					`{"model":%q,"prompt":"hello","max_tokens":16}`, model)
			},
		},
		{
			name:     "messages",
			endpoint: "/v1/messages",
			body: func(model string) string {
				return fmt.Sprintf(
					`{"model":%q,"messages":[{"role":"user","content":"hello"}],"max_tokens":16}`,
					model)
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg, _, srv, ts := setupTTFTFailoverServer(t)
			srv.SetTTFTHardReject(true)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			model := "generic-deadline-" + tc.name
			var attempts deadlineAttemptRecorder
			script := func(
				ctx context.Context,
				fp *failoverProvider,
				req protocol.InferenceRequestMessage,
				_ []byte,
			) {
				if attempts.capture(t, reg, fp, req) == 1 {
					time.Sleep(40 * time.Millisecond)
					fp.sendTypedInferenceError(
						ctx, req, protocol.FailureCodeCapacity,
						failure.ErrorReasonDeadlineUnreachable,
						http.StatusServiceUnavailable)
					return
				}
				fp.serveFull(ctx, req, model, markerFor(fp.name))
			}
			for i := 0; i < 2; i++ {
				startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name:    fmt.Sprintf("%s-provider-%d", tc.name, i),
					Version: "0.8.10", DecodeTPS: 200 - float64(i),
					Models: []failoverModelSpec{{ID: model}}, Script: script,
				})
			}

			status, body, err := postGenericInference(
				ctx, ts.URL, tc.endpoint, tc.body(model))
			if err != nil {
				t.Fatal(err)
			}
			got := attempts.snapshot()
			if status != http.StatusOK || len(got) != 2 ||
				!strings.Contains(body, markerFor(got[1].provider)) {
				t.Fatalf(
					"status=%d attempts=%+v body=%s, want invisible generic failover",
					status, got, body)
			}
			assertAttemptBudgetsDecrease(t, got)
		})
	}
}

func TestGenericDeadlineExhaustionReturnsSingle429(t *testing.T) {
	reg, st, srv, ts := setupTTFTFailoverServer(t)
	srv.SetTTFTHardReject(true)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const model = "generic-deadline-exhausted"
	script := func(
		ctx context.Context,
		fp *failoverProvider,
		req protocol.InferenceRequestMessage,
		_ []byte,
	) {
		fp.sendTypedInferenceError(
			ctx, req, protocol.FailureCodeCapacity,
			failure.ErrorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
	}
	for i := 0; i < 2; i++ {
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: fmt.Sprintf("generic-refuser-%d", i), Version: "0.8.10",
			DecodeTPS: 200 - float64(i),
			Models:    []failoverModelSpec{{ID: model}},
			Script:    script,
		})
	}

	status, body, err := postGenericInference(
		ctx, ts.URL, "/v1/completions",
		fmt.Sprintf(`{"model":%q,"prompt":"hello","max_tokens":16}`, model))
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusTooManyRequests ||
		!strings.Contains(body, "remaining deadline") {
		t.Fatalf("status=%d body=%s, want generic deadline 429", status, body)
	}
	_, rejections := waitForDeadlineTelemetry(t, st, 2, 1)
	if len(rejections) != 1 ||
		rejections[0].ReasonCode != rejectionReasonDeadlineUnreachable {
		t.Fatalf("generic rejection rows = %+v, want one deadline reason", rejections)
	}
}
