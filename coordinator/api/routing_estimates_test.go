package api

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// expectedCompletionTokensForRouting: learned value once warm (bound-clamped),
// else the client's explicit bound, else the pre-injection 256 x n default.
func TestExpectedCompletionTokensForRouting(t *testing.T) {
	t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "on")
	srv, _ := testServer(t)
	const model = "routing-estimates-model"

	// Cold + absent: 256 × n, never the injected bound.
	if got := srv.expectedCompletionTokensForRouting(model, map[string]any{"max_tokens": 8192}, false, 8192); got != 256 {
		t.Fatalf("cold/absent: expected=%d, want 256", got)
	}
	if got := srv.expectedCompletionTokensForRouting(model, map[string]any{"max_tokens": 8192, "n": 3}, false, 8192*3); got != 768 {
		t.Fatalf("cold/absent n=3: expected=%d, want 768", got)
	}
	// Cold + explicit: the client's bound (today's behaviour).
	if got := srv.expectedCompletionTokensForRouting(model, map[string]any{"max_tokens": 4000}, true, 4000); got != 4000 {
		t.Fatalf("cold/explicit: expected=%d, want 4000", got)
	}

	// Warm: learned p90 × 1.25, clamped to the forwarded bound.
	for i := 0; i < 40; i++ {
		srv.registry.RecordCompletionObservation(model, 400)
	}
	if got := srv.expectedCompletionTokensForRouting(model, map[string]any{"max_tokens": 8192}, false, 8192); got != 500 {
		t.Fatalf("warm/absent: expected=%d, want 500", got)
	}
	if got := srv.expectedCompletionTokensForRouting(model, map[string]any{"max_tokens": 300}, true, 300); got != 300 {
		t.Fatalf("warm/explicit below p90: expected=%d, want the bound 300", got)
	}

	// Kill switch: the pre-calibration cost byte-for-byte — the forwarded
	// bound for omitted AND explicit max_tokens, even with a warm calibrator.
	// (This pinned 256 before: the switch only disabled the learned value and
	// left the cold default in place, so the documented rollback of the
	// cold+absent ranking change required a deploy.)
	t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "off")
	if got := srv.expectedCompletionTokensForRouting(model, map[string]any{"max_tokens": 8192}, false, 8192); got != 8192 {
		t.Fatalf("switch off/absent: expected=%d, want the forwarded bound 8192", got)
	}
	if got := srv.expectedCompletionTokensForRouting(model, map[string]any{"max_tokens": 8192, "n": 3}, false, 8192*3); got != 8192*3 {
		t.Fatalf("switch off/absent n=3: expected=%d, want the forwarded bound %d", got, 8192*3)
	}
	if got := srv.expectedCompletionTokensForRouting(model, map[string]any{"max_tokens": 300}, true, 300); got != 300 {
		t.Fatalf("switch off/explicit: expected=%d, want 300", got)
	}

	// No registry (unit fixtures): cold rules.
	bare := &Server{}
	if got := bare.expectedCompletionTokensForRouting(model, map[string]any{}, true, 77); got != 77 {
		t.Fatalf("bare server expected=%d, want 77", got)
	}
}

// chatBodyWithoutMaxTokens is a chat request that omits every max-tokens
// field, so ensureMaxTokensBound injects the model bound (8192 default).
func chatBodyWithoutMaxTokens(t *testing.T, model string, maxTokens int) string {
	t.Helper()
	body := map[string]any{
		"model":    model,
		"messages": []map[string]any{{"role": "user", "content": "routing estimates test prompt"}},
		"stream":   false,
	}
	if maxTokens > 0 {
		body["max_tokens"] = maxTokens
	}
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal chat body: %v", err)
	}
	return string(data)
}

// routeRecordsFor polls the memory store until at least n route rows exist
// for model and returns them in insertion order.
func routeRecordsFor(t *testing.T, st *store.MemoryStore, model string, n int) []store.InferenceRouteRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var out []store.InferenceRouteRecord
		for _, rec := range st.InferenceRouteRecordsSince(time.Time{}) {
			if rec.Model == model {
				out = append(out, rec)
			}
		}
		if len(out) >= n {
			return out
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("fewer than %d route records for %s", n, model)
	return nil
}

// forwardedMaxTokens extracts max_tokens from the decrypted provider body.
func forwardedMaxTokens(t *testing.T, body []byte) int {
	t.Helper()
	var parsed map[string]any
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatalf("unmarshal forwarded body: %v", err)
	}
	n, ok := intFromRequestValue(parsed["max_tokens"])
	if !ok {
		t.Fatalf("forwarded body has no max_tokens: %s", body)
	}
	return n
}

// Through the real HTTP path and a real WebSocket provider (DecodeTPS 40): a
// request that omits max_tokens is FORWARDED with the injected 8192 bound
// (billing safety) and the route row still records that bound for
// admission/ledger, while the scheduler's decode term (this_req_ms) is scored
// from the routing estimate — 256 tokens cold, the learned p90 × 1.25 once
// the completion calibrator is warm — never the 8192 bound (204.8 s at 40
// tok/s). Before the change both cases scored the bound.
func TestRoutingEstimatesFlowThroughDispatch(t *testing.T) {
	t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "on")
	const decodeTPS = 40.0

	run := func(t *testing.T, name string, seed func(t *testing.T, reg *registry.Registry, model string), wantThisReqMin, wantThisReqMax float64) {
		t.Run(name, func(t *testing.T) {
			reg, st, ts := setupFailoverServer(t)
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			model := "routing-estimates-" + strings.ReplaceAll(name, "_", "-")
			if seed != nil {
				seed(t, reg, model)
			}
			fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
				Name: "provider-" + name, Version: "0.8.10", DecodeTPS: decodeTPS,
				Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
			})

			status, respBody, err := postChat(ctx, ts.URL, "test-key", chatBodyWithoutMaxTokens(t, model, 0))
			if err != nil {
				t.Fatalf("chat request: %v", err)
			}
			if status != 200 {
				t.Fatalf("status=%d body=%s", status, respBody)
			}

			// Forwarded body carries the injected bound (issue #33).
			select {
			case forwarded := <-fp.bodies:
				if got := forwardedMaxTokens(t, forwarded); got != defaultMaxOutputTokens {
					t.Fatalf("forwarded max_tokens=%d, want the injected bound %d", got, defaultMaxOutputTokens)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("provider never received the request body")
			}

			rec := routeRecordsFor(t, st, model, 1)[0]
			if rec.RequestedMaxTokens != defaultMaxOutputTokens {
				t.Fatalf("route requested_max_tokens=%d, want the forwarded bound %d (admission/ledger keep the worst case)", rec.RequestedMaxTokens, defaultMaxOutputTokens)
			}
			if rec.ThisReqMs < wantThisReqMin || rec.ThisReqMs > wantThisReqMax {
				t.Fatalf("this_req_ms=%.0f, want within [%.0f, %.0f] (the bound would score %.0f)",
					rec.ThisReqMs, wantThisReqMin, wantThisReqMax, float64(defaultMaxOutputTokens)/decodeTPS*1000)
			}
		})
	}

	// Cold: 256 / 40 tok/s = 6400ms decode + a small prefill term.
	run(t, "omitted_max_tokens_cold", nil, 6_000, 7_000)

	// Learned completion: p90 459 × 1.25 → 574 tokens → 14350ms decode.
	run(t, "omitted_max_tokens_learned_completion", func(t *testing.T, reg *registry.Registry, model string) {
		for i := 0; i < 50; i++ {
			reg.RecordCompletionObservation(model, 100+400*i/49)
		}
		if got := reg.ExpectedCompletionTokens(model, defaultMaxOutputTokens); got != 574 {
			t.Fatalf("seeded expected=%d, want 574", got)
		}
	}, 14_000, 15_000)

	// Kill switch, at the production layer: the same warm calibrator and the
	// same omitted-max_tokens request score the injected bound (8192 / 40 tok/s
	// = 204,800 ms) — the rollback the rollout notes promise, without a deploy.
	// Before the fix this ranked on the 256 cold default (6.4 s).
	run(t, "omitted_max_tokens_kill_switch_scores_the_bound", func(t *testing.T, reg *registry.Registry, model string) {
		for i := 0; i < 50; i++ {
			reg.RecordCompletionObservation(model, 100+400*i/49)
		}
		t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "off")
	}, 204_000, 206_000)
}

// TestCompletionObservationsFeedCalibratorLive drives the REAL settlement
// path: every provider completion (fullServeScript reports 3 completion
// tokens) reaches handleCompleteAt, which feeds the calibrator; the 30th
// crosses warm-up; a completion right-censored by its own max_tokens bound is
// skipped; and the learned value then scores the next request's decode term.
func TestCompletionObservationsFeedCalibratorLive(t *testing.T) {
	t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "on")
	reg, st, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	const model = "calibrator-feed-model"
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "feed-provider", Version: "0.8.10", DecodeTPS: 40,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	post := func(maxTokens int) {
		t.Helper()
		status, body, err := postChat(ctx, ts.URL, "test-key", chatBodyWithoutMaxTokens(t, model, maxTokens))
		if err != nil || status != 200 {
			t.Fatalf("chat: status=%d err=%v body=%s", status, err, body)
		}
	}
	waitObs := func(want int64) {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for {
			_, _, n := reg.CompletionCalibrationPercentiles(model)
			if n == want {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("observations=%d, want %d", n, want)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}

	for i := 0; i < completionCalibrationWarmup-1; i++ {
		post(64)
	}
	waitObs(completionCalibrationWarmup - 1)
	if _, learned := reg.ExpectedCompletionTokensLearned(model, 8192); learned {
		t.Fatal("learned before warm-up")
	}
	post(64)
	waitObs(completionCalibrationWarmup)
	expected, learned := reg.ExpectedCompletionTokensLearned(model, 8192)
	if !learned || expected != 64 {
		t.Fatalf("after warm-up expected=%d learned=%v, want the 64-token floor (p90 = 3)", expected, learned)
	}
	if _, p90, _ := reg.CompletionCalibrationPercentiles(model); p90 != 3 {
		t.Fatalf("p90=%v, want 3 (the fixture's completion_tokens)", p90)
	}

	// Right-censored: max_tokens 3 with a 3-token completion is the bound,
	// not the completion — skipped.
	post(3)
	post(3)
	time.Sleep(50 * time.Millisecond)
	if _, _, n := reg.CompletionCalibrationPercentiles(model); n != completionCalibrationWarmup {
		t.Fatalf("right-censored completions were recorded: n=%d", n)
	}

	// The learned value now scores the decode term: 64 / 40 tok/s = 1,600 ms
	// (+ prefill), not the 8192 bound (204,800 ms) or the cold 256 (6,400 ms).
	post(0)
	var omitted []store.InferenceRouteRecord
	for _, rec := range routeRecordsFor(t, st, model, completionCalibrationWarmup+3) {
		if rec.RequestedMaxTokens == defaultMaxOutputTokens {
			omitted = append(omitted, rec)
		}
	}
	if len(omitted) != 1 {
		t.Fatalf("route rows carrying the injected bound = %d, want exactly the one request that omitted max_tokens", len(omitted))
	}
	if got := omitted[0].ThisReqMs; got < 1_500 || got > 2_600 {
		t.Fatalf("this_req_ms=%.0f, want ~1,600 from the learned 64-token estimate", got)
	}
}

const completionCalibrationWarmup = 30

// TestExpectedCompletionNeverReachesFinishReason: finish_reason truncation
// keys on the forwarded bound, so a completion equal to the ROUTING estimate
// is "stop", and only the bound itself flips it to "length". A source-level
// pin keeps the field out of the billing/admission/rate-limit files.
func TestExpectedCompletionNeverReachesFinishReason(t *testing.T) {
	pr := &registry.PendingRequest{Model: "m", PublicModel: "m", RequestedMaxTokens: 16384, ExpectedCompletionTokens: 500}
	atExpected := protocol.UsageInfo{CompletionTokens: 500}
	if truncatedByMaxTokens(atExpected, pr.RequestedMaxTokens) {
		t.Fatal("500 completion tokens under a 16,384 bound reported as truncated")
	}
	if got := effectiveFinishReason("stop", false, atExpected, pr.RequestedMaxTokens); got != "stop" {
		t.Fatalf("finish_reason=%q at the routing estimate, want stop", got)
	}
	chunk := finalizeFinishChunk(map[string]any{"choices": []any{map[string]any{"finish_reason": "stop"}}}, atExpected, pr)
	if !strings.Contains(chunk, `"finish_reason":"stop"`) {
		t.Fatalf("finalizeFinishChunk at the routing estimate = %s, want stop", chunk)
	}
	atBound := protocol.UsageInfo{CompletionTokens: 16384}
	if got := effectiveFinishReason("stop", false, atBound, pr.RequestedMaxTokens); got != "length" {
		t.Fatalf("finish_reason=%q at the bound, want length", got)
	}

	// Source pin: only the routing plumbing may mention the field.
	allowed := map[string]bool{"consumer.go": true, "dispatch.go": true, "dispatch_plan_wiring.go": true, "routing_estimates.go": true}
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") || allowed[name] {
			continue
		}
		src, err := os.ReadFile(filepath.Clean(name))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(src), "ExpectedCompletionTokens") || strings.Contains(string(src), "expectedCompletionTokens") {
			t.Fatalf("%s references the routing-only expected completion; billing, admission, rate limiting and probes must keep RequestedMaxTokens", name)
		}
	}
}

// TestAdmissionGatesNeverReceiveExpectedCompletion pins the CALL SITES the
// registry leak table cannot: QuickCapacityCheck*, PredictServable /
// shedIfUnservable, the token gate and the first-content deadline take the
// max-tokens bound as a plain int, so a caller in the allowlisted routing
// files could hand them the routing-only expected value and every registry
// row would still pass. Every such call in api/ must be argument-free of
// expectedCompletionTokens / ExpectedCompletionTokens.
func TestAdmissionGatesNeverReceiveExpectedCompletion(t *testing.T) {
	gates := []string{
		"QuickCapacityCheck", "PredictServable", "shedIfUnservable", "shedIfModelRejected",
		"applyTokenRateLimitWithAdmission", "applyTokenRateLimit(", "FirstContentDeadline(",
		"reserveInferenceBalance", "topUpReservationForInlinedMedia",
	}
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		raw, err := os.ReadFile(filepath.Clean(name))
		if err != nil {
			t.Fatal(err)
		}
		src := string(raw)
		for _, gate := range gates {
			for from := 0; ; {
				i := strings.Index(src[from:], gate)
				if i < 0 {
					break
				}
				start := from + i
				open := strings.Index(src[start:], "(")
				if open < 0 {
					break
				}
				open += start
				// Skip the definition line ("func (s *Server) gate(") — only
				// call sites carry arguments the gate would act on.
				lineStart := strings.LastIndex(src[:start], "\n") + 1
				if strings.HasPrefix(strings.TrimSpace(src[lineStart:start]), "func ") {
					from = open + 1
					continue
				}
				depth, end := 0, -1
				for j := open; j < len(src); j++ {
					switch src[j] {
					case '(':
						depth++
					case ')':
						depth--
						if depth == 0 {
							end = j
						}
					}
					if end >= 0 {
						break
					}
				}
				if end < 0 {
					break
				}
				args := src[open : end+1]
				if strings.Contains(args, "xpectedCompletionTokens") {
					t.Fatalf("%s passes the routing-only expected completion into %s: %s", name, gate, strings.TrimSpace(args))
				}
				checked++
				from = end + 1
			}
		}
	}
	if checked < 8 {
		t.Fatalf("only %d admission-gate call sites scanned; the gate list no longer matches the code", checked)
	}
}
