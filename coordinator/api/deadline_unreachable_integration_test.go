package api

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type deadlineAttemptBudget struct {
	provider  string
	wireMS    int64
	maxTTFTMS float64
}

type deadlineAttemptRecorder struct {
	mu       sync.Mutex
	attempts []deadlineAttemptBudget
}

func (r *deadlineAttemptRecorder) capture(
	t *testing.T,
	reg *registry.Registry,
	fp *failoverProvider,
	req protocol.InferenceRequestMessage,
) int {
	t.Helper()
	var maxTTFTMS float64
	provider := reg.GetProvider(fp.registryID)
	if provider == nil {
		t.Errorf("provider %q missing while capturing deadline budget", fp.name)
	} else if pending := provider.GetPending(req.RequestID); pending == nil {
		t.Errorf("pending request %q missing on provider %q", req.RequestID, fp.name)
	} else {
		maxTTFTMS = pending.MaxTTFTMs
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	r.attempts = append(r.attempts, deadlineAttemptBudget{
		provider:  fp.name,
		wireMS:    req.FirstContentBudgetMS,
		maxTTFTMS: maxTTFTMS,
	})
	return len(r.attempts)
}

func (r *deadlineAttemptRecorder) snapshot() []deadlineAttemptBudget {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]deadlineAttemptBudget, len(r.attempts))
	copy(out, r.attempts)
	return out
}

func waitForDeadlineTelemetry(
	t *testing.T,
	st *store.MemoryStore,
	minRoutes, minRejections int,
) ([]store.InferenceRouteRecord, []store.RejectionRecord) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		routes := st.InferenceRouteRecordsSince(time.Time{})
		rejections := st.RejectionRecordsSince(time.Time{})
		if len(routes) >= minRoutes && len(rejections) >= minRejections {
			return routes, rejections
		}
		if time.Now().After(deadline) {
			t.Fatalf(
				"telemetry did not settle: routes=%d/%d rejections=%d/%d",
				len(routes), minRoutes, len(rejections), minRejections)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func assertDeadlineRefusalDidNotFeedCapacity(
	t *testing.T,
	reg *registry.Registry,
	provider *failoverProvider,
	model string,
) {
	t.Helper()
	if provider == nil {
		t.Fatal("deadline refusal provider is nil")
	}
	if reg.CapacityCooldownActive(provider.registryID, model) {
		t.Errorf("provider %q deadline refusal fed capacity cooldown", provider.name)
	}
	if reg.BudgetClampActive(provider.registryID, model) {
		t.Errorf("provider %q deadline refusal armed budget clamp", provider.name)
	}
	if rate, samples := reg.CapacityRejectRate(provider.registryID, model); rate != 0 || samples != 0 {
		t.Errorf(
			"provider %q deadline refusal fed capacity rate: rate=%v samples=%d",
			provider.name, rate, samples)
	}
	p := reg.GetProvider(provider.registryID)
	if p == nil {
		t.Fatalf("provider %q disappeared before reputation assertion", provider.name)
	}
	p.Mu().Lock()
	failedJobs := p.Reputation.FailedJobs
	totalJobs := p.Reputation.TotalJobs
	p.Mu().Unlock()
	if failedJobs != 0 || totalJobs != 0 {
		t.Errorf(
			"provider %q deadline refusal changed reputation: failed=%d total=%d",
			provider.name, failedJobs, totalJobs)
	}
}

func assertAttemptBudgetsDecrease(t *testing.T, attempts []deadlineAttemptBudget) {
	t.Helper()
	if len(attempts) < 2 {
		t.Fatalf("captured %d attempts, want at least 2", len(attempts))
	}
	for i, attempt := range attempts {
		if attempt.wireMS <= 0 {
			t.Errorf("attempt %d provider %q wire budget = %d, want positive", i, attempt.provider, attempt.wireMS)
		}
		if attempt.maxTTFTMS <= 0 {
			t.Errorf("attempt %d provider %q MaxTTFTMs = %.3f, want positive", i, attempt.provider, attempt.maxTTFTMS)
		}
		if attempt.maxTTFTMS < float64(attempt.wireMS) {
			t.Errorf(
				"attempt %d provider %q MaxTTFTMs %.3f is below later wire budget %d",
				i, attempt.provider, attempt.maxTTFTMS, attempt.wireMS)
		}
		if i > 0 {
			if attempt.wireMS >= attempts[i-1].wireMS {
				t.Errorf(
					"wire budgets did not decrease: attempt %d=%d previous=%d",
					i, attempt.wireMS, attempts[i-1].wireMS)
			}
			if attempt.maxTTFTMS >= attempts[i-1].maxTTFTMS {
				t.Errorf(
					"hard-admission budgets did not decrease: attempt %d=%.3f previous=%.3f",
					i, attempt.maxTTFTMS, attempts[i-1].maxTTFTMS)
			}
		}
	}
}

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
				errorReasonDeadlineUnreachable,
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

	byName := map[string]*failoverProvider{
		providers[0].name: providers[0],
		providers[1].name: providers[1],
	}
	assertDeadlineRefusalDidNotFeedCapacity(
		t, reg, byName[attempts[0].provider], model)

	routes, _ := waitForDeadlineTelemetry(t, st, 2, 0)
	deadlineRoutes := 0
	for _, route := range routes {
		if route.ErrorReason != errorReasonDeadlineUnreachable {
			continue
		}
		deadlineRoutes++
		if route.ErrorClass != errorClassDeadlineUnreachable {
			t.Errorf("deadline route class = %q, want %q", route.ErrorClass, errorClassDeadlineUnreachable)
		}
		if route.AdmittedButFailed {
			t.Error("pre-content deadline refusal must not be admitted-but-failed")
		}
	}
	if deadlineRoutes != 1 {
		t.Errorf("deadline route rows = %d, want 1; routes=%+v", deadlineRoutes, routes)
	}
}

func TestDispatchOneProviderExpiredClockDoesNotSend(t *testing.T) {
	reg, _, srv, ts := setupTTFTFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const model = "deadline-expired-before-wire-model"
	provider := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-expired", Version: "0.8.10", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}},
		Script: fullServeScript(model),
	})

	req := httptest.NewRequest(
		http.MethodPost,
		"/v1/chat/completions",
		strings.NewReader(buildChatBody(t, model, false, nil)),
	)
	selected, pending, _, dispatchErr, dispatchErrCode := srv.dispatchOneProvider(
		req,
		model,
		model,
		[]byte(buildChatBody(t, model, false, nil)),
		"test-key",
		nil,
		0,
		8,
		64,
		registry.TokenAdmission{},
		false,
		registry.RequestTraits{},
		nil,
		false,
		selfRoutePolicy{},
		&registry.RequestTiming{ReceivedAt: time.Now().Add(-time.Minute)},
		false,
		registry.CachePlan{},
		map[string]struct{}{},
		0,
		nil,
	)
	if selected != nil || pending != nil {
		t.Fatalf("expired dispatch selected provider=%v pending=%v", selected, pending)
	}
	if dispatchErr != errFirstContentDeadlineExpired ||
		dispatchErrCode != http.StatusGatewayTimeout {
		t.Fatalf(
			"expired dispatch = (%q,%d), want (%q,504)",
			dispatchErr, dispatchErrCode, errFirstContentDeadlineExpired)
	}
	time.Sleep(50 * time.Millisecond)
	if got := provider.dispatchCount(); got != 0 {
		t.Fatalf("expired request reached provider wire %d time(s), want 0", got)
	}
}

func TestDeadlineUnreachableAllProvidersReturnSingle429(t *testing.T) {
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
			errorReasonDeadlineUnreachable,
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
	if len(attempts) != providerCount {
		t.Fatalf(
			"dispatches = %d, want all %d untried providers (capacity cap is %d): %+v",
			len(attempts), providerCount, maxCapacityClassRetries, attempts)
	}
	assertAttemptBudgetsDecrease(t, attempts)
	for _, provider := range providers {
		assertDeadlineRefusalDidNotFeedCapacity(t, reg, provider, model)
	}

	routes, rejections := waitForDeadlineTelemetry(
		t, st, providerCount, 1)
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
		if route.ErrorReason == errorReasonDeadlineUnreachable {
			deadlineRoutes++
		}
	}
	if deadlineRoutes != providerCount {
		t.Errorf(
			"deadline route rows = %d, want %d; routes=%+v",
			deadlineRoutes, providerCount, routes)
	}
}

func postGenericInference(
	ctx context.Context,
	baseURL, endpoint, body string,
) (int, string, error) {
	req, err := http.NewRequestWithContext(
		ctx, http.MethodPost, baseURL+endpoint, strings.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	return resp.StatusCode, string(data), err
}

func TestAcceptedDoesNotStopSpeculativeFirstContentRace(t *testing.T) {
	reg, _, _, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{
		FirstContentDeadlineBase: 400 * time.Millisecond,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	const model = "accepted-still-speculates"
	var attempts deadlineAttemptRecorder
	script := func(
		ctx context.Context,
		fp *failoverProvider,
		req protocol.InferenceRequestMessage,
		_ []byte,
	) {
		if attempts.capture(t, reg, fp, req) == 1 {
			fp.sendAccepted(ctx, req)
			select {
			case <-ctx.Done():
			case <-time.After(2 * time.Second):
			}
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "accepted-primary", Version: "0.8.10", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "content-backup", Version: "0.8.10", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	status, body, err := postChat(
		ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatal(err)
	}
	got := attempts.snapshot()
	if len(got) != 2 {
		t.Fatalf("dispatches = %+v, want accepted primary plus speculative backup", got)
	}
	assertCleanFailoverStream(t, status, body, markerFor(got[1].provider))
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
				errorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
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
						errorReasonDeadlineUnreachable,
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
			errorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
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

func TestProductionConfigStreamingDeadlineExhaustionRetainsHTTP429(t *testing.T) {
	tests := []struct {
		name     string
		endpoint string
		body     func(string) string
	}{
		{
			name:     "chat completions",
			endpoint: "/v1/chat/completions",
			body: func(model string) string {
				return buildChatBody(t, model, true, nil)
			},
		},
		{
			name:     "anthropic messages",
			endpoint: "/v1/messages",
			body: func(model string) string {
				return fmt.Sprintf(
					`{"model":%q,"stream":true,"messages":[{"role":"user","content":"hello"}],"max_tokens":16}`,
					model,
				)
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reg, _, srv, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{
				FirstContentDeadlineBase: 600 * time.Millisecond,
			})
			srv.SetTTFTHardReject(true)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			model := "streaming-deadline-" + strings.ReplaceAll(test.name, " ", "-")
			script := func(
				ctx context.Context,
				_ *failoverProvider,
				_ protocol.InferenceRequestMessage,
				_ []byte,
			) {
				// Remain completely silent. The coordinator's request-absolute
				// clock—not a provider-authored refusal—must own the terminal.
				<-ctx.Done()
			}
			for i := 0; i < 2; i++ {
				startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
					Name: fmt.Sprintf("%s-provider-%d", model, i), Version: "0.8.10",
					DecodeTPS: 200 - float64(i),
					Models:    []failoverModelSpec{{ID: model}},
					Script:    script,
				})
			}

			status, body, err := postGenericInference(
				ctx, ts.URL, test.endpoint, test.body(model))
			if err != nil {
				t.Fatal(err)
			}
			if status != http.StatusTooManyRequests {
				t.Fatalf("status=%d body=%s, want terminal HTTP 429", status, body)
			}
			if !strings.Contains(body, "rate_limit_exceeded") {
				t.Fatalf("deadline rejection lost retryable body: %s", body)
			}
			if strings.Contains(body, "data:") ||
				strings.Contains(body, "event:") ||
				strings.Contains(body, ": keepalive") {
				t.Fatalf("pre-content rejection was committed as SSE: %s", body)
			}
		})
	}
}
