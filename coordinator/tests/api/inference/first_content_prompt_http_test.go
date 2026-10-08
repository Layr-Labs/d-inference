package inference_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type promptDeadlineDispatch struct {
	deadline, received time.Time
	wireMS             int64
	estimate, max      int
	work               protocol.PromptWork
}

func promptDeadlineBody(model, endpoint, input string, stream bool) string {
	field := fmt.Sprintf(`"messages":[{"role":"user","content":%q}]`, input)
	if endpoint == "/v1/responses" {
		field = fmt.Sprintf(`"input":%q`, input)
	}
	if endpoint == "/v1/completions" {
		field = fmt.Sprintf(`"prompt":%q`, input)
	}
	return fmt.Sprintf(`{"model":%q,%s,"max_tokens":32,"stream":%t}`, model, field, stream)
}

func startPromptDeadlineProvider(t *testing.T, ctx context.Context, ts *httptest.Server, s *serverFixture, f promptDeadlineFixture, seen chan<- promptDeadlineDispatch, script ...inferenceScript) *failoverProvider {
	t.Helper()
	p := startFailoverProvider(t, ctx, ts, s.registry, failoverProviderConfig{Name: "prompt-deadline-provider", Version: "0.9.17", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: f.model}}, Script: func(ctx context.Context, fp *failoverProvider, request protocol.InferenceRequestMessage, body []byte) {
			pending := s.registry.GetProvider(fp.registryID).GetPending(request.RequestID)
			if pending == nil || request.PromptWork == nil {
				t.Error("dispatch omitted pending prompt work")
				return
			}
			seen <- promptDeadlineDispatch{deadline: pending.FirstContentDeadline, received: pending.Timing.ReceivedAt,
				wireMS: request.FirstContentBudgetMS, estimate: pending.EstimatedPromptTokens, max: pending.RequestedMaxTokens, work: *request.PromptWork}
			if len(script) > 0 {
				script[0](ctx, fp, request, body)
			} else {
				fp.serveFull(ctx, request, f.model, "DEADLINE_OK")
			}
		}})
	s.registry.UpdateModelWeightHashes(p.registryID, map[string]string{f.model: f.hash})
	provider := s.registry.GetProvider(p.registryID)
	provider.Mu().Lock()
	provider.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{Model: f.model, State: "idle", MaxConcurrency: 8,
			ActiveTokenBudgetMax: 200_000, PromptWorkIdentity: &protocol.PromptWorkIdentity{ModelArtifactHash: f.hash, PromptContractID: f.contract}}}}
	provider.Mu().Unlock()
	reportMeasuredFirstContentEvidence(t, s.registry, p.registryID, f.model, 10_000, 100)
	return p
}

func TestPromptWorkDeadlineHTTPAvoidsFalseProviderDeadlineRefusal(t *testing.T) {
	_, _, s, ts := setupTTFTFailoverServerWithConfig(t, TestServerConfig{FirstContentDeadlineBase: 9 * time.Second})
	t.Cleanup(s.Close)
	f := newPromptDeadlineFixture(t, s)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	seen := make(chan promptDeadlineDispatch, 4)
	// Match the observed failure mechanism without sleeping through a real
	// prefill: exact work needs12.842s at450TPS, above a3606-token12.606s
	// heuristic budget but below the exact5779-token14.779s budget.
	const projectedMS = int64(5779 * 1000 / 450)
	startPromptDeadlineProvider(t, ctx, ts, s, f, seen, func(ctx context.Context, fp *failoverProvider, request protocol.InferenceRequestMessage, _ []byte) {
		if request.FirstContentBudgetMS < projectedMS {
			fp.sendTypedInferenceError(ctx, request, protocol.FailureCodeCapacity, failure.ErrorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
			return
		}
		fp.serveFull(ctx, request, f.model, "DEADLINE_OK")
	})
	input := "fixture_count=5779 " + strings.Repeat("x", 14_400)
	status, body, err := postGenericInference(ctx, ts.URL, "/v1/chat/completions", promptDeadlineBody(f.model, "/v1/chat/completions", input, false))
	if err != nil || status != http.StatusOK || !strings.Contains(body, "DEADLINE_OK") {
		t.Fatalf("false unreachable refusal survived: HTTP%d err%v body%s", status, err, body)
	}
	dispatch := <-seen
	if heuristic := s.FirstContentDeadline(f.model, dispatch.estimate); heuristic.Milliseconds() >= projectedMS {
		t.Fatalf("fixture no longer reproduces undercount: estimate%d heuristic%v projected%dms", dispatch.estimate, heuristic, projectedMS)
	}
	if dispatch.deadline.Sub(dispatch.received) != 14779*time.Millisecond || dispatch.wireMS < projectedMS {
		t.Fatalf("exact ingress budget inconsistent: %+v", dispatch)
	}
}

func TestPromptWorkDeadlineHTTPUsesExactCountBeforeDispatch(t *testing.T) {
	_, _, s, ts := setupTTFTFailoverServerWithConfig(t, TestServerConfig{FirstContentDeadlineBase: 9 * time.Second})
	t.Cleanup(s.Close)
	f := newPromptDeadlineFixture(t, s)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	seen := make(chan promptDeadlineDispatch, 1)
	startPromptDeadlineProvider(t, ctx, ts, s, f, seen)
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, stream := range []bool{false, true} {
			for _, count := range []int{5779, 1200} {
				t.Run(fmt.Sprintf("%s/stream%t/count%d", endpoint, stream, count), func(t *testing.T) {
					input := fmt.Sprintf("fixture_count=%d fixture_delay_ms=80", count)
					if count == 1200 {
						input += strings.Repeat("abcdefgh", 2000)
					}
					status, body, err := postGenericInference(ctx, ts.URL, endpoint, promptDeadlineBody(f.model, endpoint, input, stream))
					if err != nil || status != http.StatusOK || !strings.Contains(body, "DEADLINE_OK") {
						t.Fatalf("HTTP%d err%v body%s", status, err, body)
					}
					dispatch := <-seen
					want := s.FirstContentDeadline(f.model, count)
					if dispatch.work.Source != protocol.PromptWorkExact || dispatch.work.PromptTokens != count ||
						dispatch.deadline.Sub(dispatch.received) != want {
						t.Fatalf("HTTP did not reconcile exact token term: %+v", dispatch)
					}
					if dispatch.wireMS > want.Milliseconds()-70 || dispatch.wireMS < want.Milliseconds()-1500 || dispatch.estimate == count || dispatch.max != 32 {
						t.Fatalf("planning restarted clock or changed physical input: %+v", dispatch)
					}
				})
			}
		}
	}
}

func TestPromptWorkDeadlineHTTPFailedPlannerRetainsColdBudget(t *testing.T) {
	_, _, s, ts := setupTTFTFailoverServerWithConfig(t, TestServerConfig{FirstContentDeadlineBase: 9 * time.Second})
	t.Cleanup(s.Close)
	f := newPromptDeadlineFixture(t, s)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	seen := make(chan promptDeadlineDispatch, 1)
	startPromptDeadlineProvider(t, ctx, ts, s, f, seen)
	for _, input := range []string{"fixture_error", "fixture_count=0", "fixture_count=5779 fixture_wrong_contract"} {
		t.Run(input, func(t *testing.T) {
			before, err := f.supervisor.Client().Metrics(ctx)
			if err != nil {
				t.Fatal(err)
			}
			status, body, err := postGenericInference(ctx, ts.URL, "/v1/chat/completions", promptDeadlineBody(f.model, "/v1/chat/completions", input, false))
			if err != nil || status != http.StatusOK || !strings.Contains(body, "DEADLINE_OK") {
				t.Fatalf("cold fallback HTTP%d err%v body%s", status, err, body)
			}
			dispatch := <-seen
			if dispatch.work.Source != protocol.PromptWorkHeuristic || dispatch.deadline.Sub(dispatch.received) != s.FirstContentDeadline(f.model, dispatch.estimate) {
				t.Fatalf("planner failure changed initial budget: %+v", dispatch)
			}
			after, err := f.supervisor.Client().Metrics(ctx)
			if err != nil || after.Metrics.Plans.Started-before.Metrics.Plans.Started != 1 {
				t.Fatalf("failed planning repeated: %d→%d err%v", before.Metrics.Plans.Started, after.Metrics.Plans.Started, err)
			}
		})
	}
}

func TestPromptWorkDeadlineHTTPPreservesEarlierCallerCutoff(t *testing.T) {
	_, _, s, ts := setupTTFTFailoverServerWithConfig(t, TestServerConfig{FirstContentDeadlineBase: 9 * time.Second})
	t.Cleanup(s.Close)
	f := newPromptDeadlineFixture(t, s)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	seen := make(chan promptDeadlineDispatch, 1)
	provider := startPromptDeadlineProvider(t, ctx, ts, s, f, seen)
	const cutoff = 300 * time.Millisecond
	consumer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		bounded, cancel := context.WithTimeout(r.Context(), cutoff)
		defer cancel()
		s.Handler().ServeHTTP(w, r.WithContext(bounded))
	}))
	t.Cleanup(consumer.Close)
	status, body, err := postGenericInference(ctx, consumer.URL, "/v1/chat/completions",
		promptDeadlineBody(f.model, "/v1/chat/completions", "fixture_count=5779 fixture_delay_ms=80", false))
	if err != nil || status != http.StatusOK || !strings.Contains(body, "DEADLINE_OK") {
		t.Fatalf("caller cutoff HTTP%d err%v body%s", status, err, body)
	}
	dispatch := <-seen
	if duration := dispatch.deadline.Sub(dispatch.received); duration <= 0 || duration > cutoff || dispatch.wireMS > 230 {
		t.Fatalf("earlier caller cutoff was replaced: %+v", dispatch)
	}
	before := provider.dispatches.Load()
	started := time.Now()
	_, _, _ = postGenericInference(ctx, consumer.URL, "/v1/chat/completions",
		promptDeadlineBody(f.model, "/v1/chat/completions", "fixture_count=5779 fixture_delay_ms=2000", false))
	if elapsed := time.Since(started); elapsed > time.Second || provider.dispatches.Load() != before {
		t.Fatalf("cancelled planning reached provider: elapsed%v dispatches%d→%d", elapsed, before, provider.dispatches.Load())
	}
}
