package inference_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// This oracle compiles against the original API, using the actual encrypted
// HTTP/provider fixture. It checks planning visibility, not native cache adoption.
func TestCachePlanningDecisionMissingDependenciesHTTP(t *testing.T) {
	endpoints := []struct{ name, path, fields string }{
		{"chat", "/v1/chat/completions", `"messages":[{"role":"user","content":"planning-fixture"}],"max_tokens":64`},
		{"responses", "/v1/responses", `"input":"planning-fixture","max_output_tokens":64`},
		{"completions", "/v1/completions", `"prompt":"planning-fixture","max_tokens":64`},
		{"messages", "/v1/messages", `"messages":[{"role":"user","content":"planning-fixture"}],"max_tokens":64`},
	}
	for _, endpoint := range endpoints {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint.name, stream), func(t *testing.T) {
				reg, _, server, transport := setupTTFTFailoverServer(t)
				t.Cleanup(server.Close)
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()
				const model = "planning-decision-fixture"
				provider := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
					Name: "planning-decision-provider", Version: "0.8.10", DecodeTPS: 100,
					Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
				})
				setPrefixCacheProtocol(t, reg, provider, 1)
				if planner := server.NewCachePlanner(); planner.Artifacts != nil || planner.Contract != nil || planner.Preloader != nil {
					t.Fatal("fixture unexpectedly has planning dependencies")
				}
				body := fmt.Sprintf(`{"model":%q,%s,"stream":%t}`, model, endpoint.fields, stream)
				correlation := fmt.Sprintf("planning-fixture-%s-%t", endpoint.name, stream)
				body = strings.ReplaceAll(body, "planning-fixture", correlation)
				providerBody := postAndCapture(t, ctx, transport, provider, endpoint.path, "test-key", body)
				if !strings.Contains(string(providerBody), correlation) {
					t.Fatal("provider did not decrypt this logical request")
				}
				if provider.dispatchCount() != 1 || len(provider.bodies) != 0 {
					t.Error("ordinary inference did not complete one dispatch")
				}
				snapshot := server.observation.Metrics().Snapshot()
				var decisions, legacyPlans int64
				for name, value := range snapshot.Counters {
					if strings.HasPrefix(name, "exact_cache_planning_decision_total{") {
						decisions += value
					}
					if strings.HasPrefix(name, "exact_cache_plan_total{") {
						legacyPlans += value
					}
				}
				// Check preservation before the intended baseline visibility failure.
				if legacyPlans != 0 {
					t.Errorf("no Registry invocation expected: legacy plans=%d", legacyPlans)
				}
				if decisions != 1 || snapshot.Counters["exact_cache_planning_decision_total{reason=dependencies_unavailable}"] != 1 {
					t.Errorf("post-preflight planning decision missing: total=%d dependencies_unavailable=%d",
						decisions, snapshot.Counters["exact_cache_planning_decision_total{reason=dependencies_unavailable}"])
				}
			})
		}
	}
}

func TestCachePlanningUDSVerifiedLifecycleAndExpiredClock(t *testing.T) {
	s := newCachePlanningOwner(t)
	f := newCachePlanningUDSFixture(t, s.Owner, s.registry)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	originalDeadline, _ := ctx.Deadline()
	input := f.input()
	input.ReceivedAt, input.FirstContentBudget = time.Now(), time.Second
	plan := s.NewCachePlanner().PlanResult(ctx, input).Plan
	if plan.CacheScope == "" || plan.PromptTokenCount != 257 || len(plan.Boundaries) != 1 || plan.Boundaries[0].TokenCount != 256 || plan.Boundaries[0].ChainHash != strings.Repeat("c", 64) {
		t.Fatal("verified lifecycle did not produce expected generation-bound plan")
	}
	state := f.state(t)
	if state.Plans != 1 || state.Active != 0 || state.LastContract != f.contract || state.LastScope != plan.CacheScope || !bytes.Equal(state.LastBody, input.Body) {
		t.Fatalf("actual UDS planning contract differs: %+v", state)
	}
	deadline, _ := ctx.Deadline()
	if ctx.Err() != nil || !deadline.Equal(originalDeadline) {
		t.Fatal("planning child cleanup changed parent")
	}
	input.ReceivedAt = time.Now().Add(-time.Second)
	input.FirstContentBudget = time.Millisecond
	if expired := s.NewCachePlanner().PlanResult(ctx, input).Plan; expired.CacheScope != "" || len(expired.Boundaries) != 0 {
		t.Fatal("expired request retained a plan")
	}
	if state := f.state(t); state.Plans != 1 || state.Active != 0 {
		t.Fatal("expired original clock submitted UDS work")
	}
	if s.observation.Metrics().Snapshot().Counters["exact_cache_plan_total{outcome=sidecar_error}"] != 1 {
		t.Fatal("expired client invocation lost legacy accounting")
	}
	if ctx.Err() != nil {
		t.Fatal("expired planning child canceled parent")
	}
	input.ReceivedAt, input.FirstContentBudget = time.Time{}, 0
	if recovered := s.NewCachePlanner().PlanResult(ctx, input).Plan; recovered.CacheScope == "" {
		t.Fatal("exempt request did not recover after expired plan")
	}
	if f.supervisor.Status().Restarts != 0 {
		t.Fatal("ordinary plan expiry restarted sidecar")
	}
}

func TestCachePlanningUDSOriginalDeadlineBoundsBlockedWork(t *testing.T) {
	s := newCachePlanningOwner(t)
	f := newCachePlanningUDSFixture(t, s.Owner, s.registry)
	f.setMode(t, "block")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	input := f.input()
	input.ReceivedAt = time.Now().Add(-time.Second)
	input.FirstContentBudget = 1500 * time.Millisecond
	wantDeadline := input.ReceivedAt.Add(input.FirstContentBudget)
	beforeTimeouts := f.supervisor.Client().Stats().Timeouts
	type result struct {
		plan registry.CachePlan
		at   time.Time
	}
	results := make(chan result, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		plan := s.NewCachePlanner().PlanResult(ctx, input).Plan
		results <- result{plan: plan, at: time.Now()}
	}()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Error("planning caller did not drain")
		}
	}()
	// Readiness was established before the clock began. Observe actual blocked
	// work, and prove the health connection still works while it is active.
	f.waitState(t, func(state cachePlanningHelperState) bool { return state.Plans == 1 && state.Active == 1 })
	if err := f.supervisor.Client().Health(context.Background()); err != nil {
		t.Errorf("planning occupied control capacity: %v", err)
	}
	timer := time.NewTimer(time.Until(wantDeadline.Add(500 * time.Millisecond)))
	defer timer.Stop()
	var got result
	timely := true
	select {
	case got = <-results:
	case <-timer.C:
		timely = false
		t.Error("optional planning outlived the original first-content clock; client timeout is two seconds")
		cancel()
		select {
		case got = <-results:
		case <-time.After(2 * time.Second):
			t.Fatal("canceled counterfactual planner did not return")
		}
	}
	if got.plan.CacheScope != "" || len(got.plan.Boundaries) != 0 {
		t.Error("blocked expired planning retained cache participation")
	}
	if timely {
		if got.at.Before(wantDeadline) {
			t.Error("planning subtracted elapsed time twice or ended before its original deadline")
		}
		if ctx.Err() != nil {
			t.Error("planning deadline canceled the still-live parent")
		}
		if f.supervisor.Client().Stats().Timeouts != beforeTimeouts+1 {
			t.Error("the bounded return was not a planner timeout")
		}
	}
	f.waitState(t, func(state cachePlanningHelperState) bool { return state.Active == 0 && state.Canceled == 1 })
	metrics, err := f.supervisor.Client().Metrics(context.Background())
	if err != nil || metrics.PlanningPermitsAvailable != 1 {
		t.Errorf("actual helper did not drain: metrics=%+v error=%v", metrics, err)
	}
	f.setMode(t, "normal")
	if recovered := s.NewCachePlanner().PlanResult(context.Background(), f.input()).Plan; recovered.CacheScope == "" {
		t.Error("planner did not recover after cancellation")
	}
	if f.supervisor.Status().Restarts != 0 {
		t.Error("ordinary cancellation restarted the child")
	}
}

func TestCachePlanningHTTPDeadlineAndExemption(t *testing.T) {
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, exempt := range []bool{false, true} {
			for _, stream := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/exempt=%t/stream=%t", endpoint, exempt, stream), func(t *testing.T) {
					config := TestServerConfig{FirstContentDeadlineBase: 200 * time.Millisecond}
					if exempt {
						config.FirstContentSLAAccounts = []string{}
					}
					reg, _, server, transport := setupTTFTFailoverServerWithConfig(t, config)
					t.Cleanup(server.Close)
					ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
					defer cancel()
					const model = "planning-fixture"
					provider := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
						Name: "planning-clock-provider", Version: "0.8.15", DecodeTPS: 1000,
						Models: []failoverModelSpec{{ID: model}},
						Script: func(ctx context.Context, fp *failoverProvider, request protocol.InferenceRequestMessage, _ []byte) {
							fp.serveFull(ctx, request, model, "PLANNING_OK")
						},
					})
					setPrefixCacheProtocol(t, reg, provider, 1)
					f := newCachePlanningUDSFixture(t, server.Owner, server.registry, provider.registryID)
					f.setMode(t, "delayed")
					fields := `"messages":[{"role":"user","content":"hello"}]`
					if endpoint == "/v1/responses" {
						fields = `"input":"hello"`
					} else if endpoint == "/v1/completions" {
						fields = `"prompt":"hello"`
					}
					body := fmt.Sprintf(`{"model":%q,%s,"max_tokens":16,"stream":%t}`, model, fields, stream)
					status, response, err := postGenericInference(ctx, transport.URL, endpoint, body)
					if err != nil {
						t.Fatal(err)
					}
					state := f.waitState(t, func(state cachePlanningHelperState) bool { return state.Active == 0 })
					if state.Plans != 1 {
						t.Fatalf("request did not reach one actual UDS plan: %+v", state)
					}
					outcome := "sidecar_error"
					if exempt {
						outcome = "planned"
						if status != http.StatusOK || cachePlanningResponseText(endpoint, stream, response) != "PLANNING_OK" || provider.dispatchCount() != 1 {
							t.Errorf("exempt inference: status=%d dispatches=%d response=%s", status, provider.dispatchCount(), response)
						}
						if state.Canceled != 0 || f.supervisor.Client().Stats().Timeouts != 0 {
							t.Error("exempt planning acquired an artificial deadline")
						}
						if err := cachePlanningResponseTerminalError(endpoint, stream, response); err != nil {
							t.Errorf("exempt response framing: %v", err)
						}
					} else {
						if status != http.StatusTooManyRequests || provider.dispatchCount() != 0 || len(provider.bodies) != 0 {
							t.Errorf("expired planning dispatched late: status=%d dispatches=%d", status, provider.dispatchCount())
						}
						if state.Canceled != 1 || f.supervisor.Client().Stats().Timeouts != 1 {
							t.Error("nonexempt original deadline did not cancel actual planning")
						}
						pending := reg.GetProvider(provider.registryID)
						if pending == nil {
							t.Fatal("provider disappeared before post-terminal verification")
						}
						awaitCondition(t, time.Second, func() bool {
							return pending.PendingCount() == 0 && reg.Queue().QueueSize(model) == 0
						}, "expired request drained provider and queue ownership")
						// Keep the real transport alive after terminal/drain. This is
						// a bounded quiet boundary, not a latency benchmark.
						quiet := time.NewTimer(100 * time.Millisecond)
						select {
						case <-provider.bodies:
							t.Error("encrypted dispatch arrived after the expired HTTP terminal")
						case <-ctx.Done():
							t.Error("fixture ended before the quiet boundary")
						case <-quiet.C:
						}
						quiet.Stop()
						if provider.dispatchCount() != 0 || pending.PendingCount() != 0 || reg.Queue().QueueSize(model) != 0 {
							t.Error("expired request recreated dispatch or queue ownership")
						}
					}
					snapshot := server.observation.Metrics().Snapshot()
					if snapshot.Counters["exact_cache_plan_total{outcome="+outcome+"}"] != 1 ||
						snapshot.Counters["exact_cache_planning_decision_total{reason="+outcome+"}"] != 1 {
						t.Errorf("request decision/legacy population mismatch for %s", outcome)
					}
					if f.supervisor.Status().Restarts != 0 {
						t.Error("ordinary planning deadline restarted the child")
					}
				})
			}
		}
	}
}

func cachePlanningResponseTerminalError(endpoint string, stream bool, body string) error {
	if !stream {
		var response map[string]any
		if err := json.Unmarshal([]byte(body), &response); err != nil {
			return err
		}
		if response["error"] != nil {
			return fmt.Errorf("response contains an error")
		}
		switch endpoint {
		case "/v1/responses":
			if response["status"] == "completed" {
				return nil
			}
		case "/v1/messages":
			if reason, ok := response["stop_reason"].(string); ok && reason != "" && response["type"] == "message" {
				return nil
			}
		default:
			if choices, ok := response["choices"].([]any); ok && len(choices) != 0 {
				choice, _ := choices[0].(map[string]any)
				if reason, ok := choice["finish_reason"].(string); ok && reason != "" {
					return nil
				}
			}
		}
		return fmt.Errorf("missing endpoint completion marker")
	}
	body = strings.ReplaceAll(body, "\r\n", "\n")
	terminals, lastType := 0, ""
	for _, data := range parseSSEDataLines(body) {
		var event map[string]any
		if err := json.Unmarshal([]byte(data), &event); err != nil {
			return err
		}
		kind, _ := event["type"].(string)
		lastType = kind
		if event["error"] != nil || kind == "error" || kind == "response.failed" || kind == "response.incomplete" {
			return fmt.Errorf("stream contains an error or incomplete event")
		}
		if endpoint == "/v1/responses" && kind == "response.completed" {
			response, _ := event["response"].(map[string]any)
			if response["status"] != "completed" {
				return fmt.Errorf("Responses terminal is not completed")
			}
			terminals++
		}
		if endpoint == "/v1/messages" && kind == "message_stop" {
			terminals++
		}
	}
	if endpoint == "/v1/chat/completions" || endpoint == "/v1/completions" {
		if strings.Count(body, "data: [DONE]") == 1 && strings.HasSuffix(strings.TrimSpace(body), "data: [DONE]") {
			return nil
		}
	} else if terminals == 1 && ((endpoint == "/v1/responses" && lastType == "response.completed") ||
		(endpoint == "/v1/messages" && lastType == "message_stop")) {
		return nil
	}
	return fmt.Errorf("missing, duplicate or nonfinal stream terminal")
}

// Read only semantic output fields. A sentinel in an ID, model name or other
// envelope metadata must not satisfy the successful-generation control.
func cachePlanningResponseText(endpoint string, stream bool, body string) string {
	parts := []string{body}
	if stream {
		parts = parseSSEDataLines(body)
	}
	var text strings.Builder
	appendText := func(value any) {
		if value, ok := value.(string); ok {
			text.WriteString(value)
		}
	}
	for _, part := range parts {
		var value map[string]any
		if json.Unmarshal([]byte(part), &value) != nil {
			continue // The separate framing oracle rejects malformed events.
		}
		switch endpoint {
		case "/v1/chat/completions", "/v1/completions":
			choices, _ := value["choices"].([]any)
			for _, raw := range choices {
				choice, _ := raw.(map[string]any)
				if endpoint == "/v1/completions" {
					appendText(choice["text"])
				} else {
					field := "message"
					if stream {
						field = "delta"
					}
					message, _ := choice[field].(map[string]any)
					appendText(message["content"])
				}
			}
		case "/v1/responses":
			if stream {
				if value["type"] == "response.output_text.delta" {
					appendText(value["delta"])
				}
			} else {
				items, _ := value["output"].([]any)
				for _, raw := range items {
					item, _ := raw.(map[string]any)
					blocks, _ := item["content"].([]any)
					for _, raw := range blocks {
						block, _ := raw.(map[string]any)
						if block["type"] == "output_text" {
							appendText(block["text"])
						}
					}
				}
			}
		case "/v1/messages":
			if stream {
				if value["type"] == "content_block_delta" {
					delta, _ := value["delta"].(map[string]any)
					if delta["type"] == "text_delta" {
						appendText(delta["text"])
					}
				}
			} else {
				blocks, _ := value["content"].([]any)
				for _, raw := range blocks {
					block, _ := raw.(map[string]any)
					if block["type"] == "text" {
						appendText(block["text"])
					}
				}
			}
		}
	}
	return text.String()
}

func TestCachePlanningResponseTextOracle(t *testing.T) {
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/completions", "/v1/responses", "/v1/messages"} {
		for _, stream := range []bool{false, true} {
			body := `{"id":"PLANNING_OK","model":"PLANNING_OK","text":"PLANNING_OK","choices":[{"finish_reason":"stop"}]}`
			if stream {
				body = "data: " + body + "\n\ndata: [DONE]\n\n"
			}
			if got := cachePlanningResponseText(endpoint, stream, body); got != "" {
				t.Errorf("%s stream=%t accepted metadata sentinel as output: %q", endpoint, stream, got)
			}
		}
	}
}

func TestCachePlanningResponseTerminalOracle(t *testing.T) {
	for _, tc := range []struct {
		name, endpoint, body string
		stream, valid        bool
	}{
		{"empty 200", "/v1/chat/completions", `{}`, false, false},
		{"content without finish", "/v1/chat/completions", `{"choices":[{"message":{"content":"PLANNING_OK"}}]}`, false, false},
		{"missing stream terminal", "/v1/chat/completions", "data: {\"choices\":[{\"delta\":{\"content\":\"PLANNING_OK\"}}]}\n\n", true, false},
		{"duplicate terminal", "/v1/chat/completions", "data: [DONE]\n\ndata: [DONE]\n\n", true, false},
		{"late event", "/v1/messages", "data: {\"type\":\"message_stop\"}\n\ndata: {\"type\":\"content_block_delta\"}\n\n", true, false},
		{"failed Responses terminal", "/v1/responses", "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"incomplete\"}}\n\n", true, false},
		{"complete chat", "/v1/chat/completions", `{"choices":[{"finish_reason":"stop"}]}`, false, true},
		{"complete Responses", "/v1/responses", "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n", true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if valid := cachePlanningResponseTerminalError(tc.endpoint, tc.stream, tc.body) == nil; valid != tc.valid {
				t.Fatalf("terminal accepted=%t want=%t", valid, tc.valid)
			}
		})
	}
}

func TestCachePlanningUDSZeroClocksAndRegistryPrecedence(t *testing.T) {
	s := newCachePlanningOwner(t)
	f := newCachePlanningUDSFixture(t, s.Owner, s.registry)
	for _, tc := range []struct {
		name     string
		received time.Time
		budget   time.Duration
	}{
		{"missing receipt", time.Time{}, time.Second},
		{"exempt old receipt", time.Now().Add(-time.Hour), 0},
		{"nonpositive old receipt", time.Now().Add(-time.Hour), -time.Second},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := f.input()
			input.ReceivedAt, input.FirstContentBudget = tc.received, tc.budget
			if plan := s.NewCachePlanner().PlanResult(context.Background(), input).Plan; plan.CacheScope == "" {
				t.Fatal("passthrough clock unexpectedly blocked planning")
			}
		})
	}
	before := f.state(t).Plans
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.registry.ConfigureCacheRouting(registry.CacheRoutingConfig{Mode: registry.CacheRoutingOff, ActivationPct: 100}); err != nil {
		t.Fatal(err)
	}
	media := f.input()
	media.HasMedia = true
	s.NewCachePlanner().PlanResult(ctx, media)
	s.NewCachePlanner().PlanResult(ctx, f.input())
	snapshot := s.observation.Metrics().Snapshot()
	for _, reason := range []string{"ineligible", "off"} {
		if snapshot.Counters["exact_cache_plan_total{outcome="+reason+"}"] != 1 ||
			snapshot.Counters["exact_cache_planning_decision_total{reason="+reason+"}"] != 1 {
			t.Errorf("Registry precedence lost for %s", reason)
		}
		if snapshot.Histograms["exact_cache_plan_latency_ms{outcome="+reason+"}"].Count != 0 {
			t.Error("non-client decision gained a legacy sidecar latency sample")
		}
	}
	if f.state(t).Plans != before {
		t.Error("media/off precedence submitted sidecar work")
	}
	missing := f.input()
	missing.Model = "unprovisioned-model"
	s.NewCachePlanner().PlanResult(ctx, missing)
	if s.observation.Metrics().Snapshot().Counters["exact_cache_planning_decision_total{reason=artifact_missing}"] != 1 {
		t.Error("artifact prerequisite did not retain precedence over Registry/off")
	}
	f.controller.Close()
	s.NewCachePlanner().PlanResult(context.Background(), f.input())
	if s.observation.Metrics().Snapshot().Counters["exact_cache_planning_decision_total{reason=preload_not_ready}"] != 1 {
		t.Error("stopped real preload lifecycle was not classified")
	}
}

func TestCachePlanningUDSParentCancellationAndEarlierDeadline(t *testing.T) {
	for _, explicitCancel := range []bool{true, false} {
		t.Run(fmt.Sprintf("explicit-cancel=%t", explicitCancel), func(t *testing.T) {
			s := newCachePlanningOwner(t)
			f := newCachePlanningUDSFixture(t, s.Owner, s.registry)
			f.setMode(t, "block")
			input := f.input()
			input.ReceivedAt, input.FirstContentBudget = time.Now(), 5*time.Second
			var ctx context.Context
			var cancel context.CancelFunc
			var parentDeadline time.Time
			if explicitCancel {
				ctx, cancel = context.WithCancel(context.Background())
			} else {
				parentDeadline = time.Now().Add(500 * time.Millisecond)
				ctx, cancel = context.WithDeadline(context.Background(), parentDeadline)
			}
			results := make(chan registry.CachePlan, 1)
			done := make(chan struct{})
			go func() { defer close(done); results <- s.NewCachePlanner().PlanResult(ctx, input).Plan }()
			defer func() {
				cancel()
				select {
				case <-done:
				case <-time.After(2 * time.Second):
					t.Error("parent-bound planner did not drain")
				}
			}()
			f.waitState(t, func(state cachePlanningHelperState) bool { return state.Plans == 1 && state.Active == 1 })
			if explicitCancel {
				cancel()
			}
			select {
			case plan := <-results:
				if plan.CacheScope != "" {
					t.Error("canceled parent retained participation")
				}
			case <-time.After(time.Second):
				t.Fatal("parent cancellation/deadline did not bound planning before the longer client/budget timeouts")
			}
			if explicitCancel && ctx.Err() != context.Canceled {
				t.Error("explicit parent cancellation changed cause")
			}
			if !explicitCancel && (ctx.Err() != context.DeadlineExceeded || time.Now().Before(parentDeadline)) {
				t.Error("earlier parent deadline was not preserved")
			}
			f.waitState(t, func(state cachePlanningHelperState) bool { return state.Active == 0 && state.Canceled == 1 })
			f.setMode(t, "normal")
			if s.NewCachePlanner().PlanResult(context.Background(), f.input()).Plan.CacheScope == "" {
				t.Error("canceled parent poisoned subsequent planning")
			}
			if f.supervisor.Status().Restarts != 0 {
				t.Error("parent cancellation restarted the helper")
			}
		})
	}
}
