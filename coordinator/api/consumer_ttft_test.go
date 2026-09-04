package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWriteServiceUnavailableSetsRetryAfter(t *testing.T) {
	srv, _ := testServer(t)
	w := httptest.NewRecorder()
	srv.writeServiceUnavailable(w, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), "gpt-oss-20b")

	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}
	if ra := w.Header().Get("Retry-After"); ra == "" {
		t.Error("Retry-After header missing")
	} else if n, err := strconv.Atoi(ra); err != nil || n < 1 {
		t.Errorf("Retry-After = %q, want positive integer seconds", ra)
	}
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body.Error.Code != "service_unavailable" {
		t.Errorf("code = %q, want service_unavailable", body.Error.Code)
	}
}

func TestTTFTDeadlineExact(t *testing.T) {
	srv, _ := testServer(t)
	tests := []struct {
		model       string
		inputTokens int
		want        time.Duration
	}{
		{model: "ordinary-model", inputTokens: 0, want: 5 * time.Second},
		{model: "ordinary-model", inputTokens: 1, want: 5*time.Second + time.Millisecond},
		{model: "ordinary-model", inputTokens: 5_000, want: 10 * time.Second},
		{model: "ordinary-model", inputTokens: 5_001, want: 10*time.Second + time.Millisecond},
		{model: modelpolicy.Qwen3VL30BA3BInstructModelID, inputTokens: 0, want: 4 * time.Second},
		{model: modelpolicy.Qwen3VL30BA3BInstructModelID, inputTokens: 1, want: 4*time.Second + time.Millisecond},
		{model: modelpolicy.Qwen3VL30BA3BInstructModelID + "-preview", inputTokens: 0, want: 5 * time.Second},
	}

	for _, tt := range tests {
		if got := srv.FirstContentDeadline(tt.model, tt.inputTokens); got != tt.want {
			t.Fatalf("FirstContentDeadline(%q, %d) = %v, want %v", tt.model, tt.inputTokens, got, tt.want)
		}
	}
}

func TestFirstContentDeadlineIsServerOwned(t *testing.T) {
	ordinary, _ := testServer(t)
	productionLike, _ := testServerWithConfig(t, ServerConfig{
		FirstContentDeadlineBase: 9 * time.Second,
	})

	const promptTokens = 321
	if got, want := productionLike.FirstContentDeadline("ordinary-model", promptTokens), 9*time.Second+321*time.Millisecond; got != want {
		t.Fatalf("production-like deadline = %v, want %v", got, want)
	}
	if got, want := ordinary.FirstContentDeadline("ordinary-model", promptTokens), 5*time.Second+321*time.Millisecond; got != want {
		t.Fatalf("ordinary deadline changed by another server: got %v, want %v", got, want)
	}
	if got, want := productionLike.FirstContentDeadline(
		modelpolicy.Qwen3VL30BA3BInstructModelID, promptTokens,
	), 4*time.Second+321*time.Millisecond; got != want {
		t.Fatalf("Qwen3-VL production-like deadline = %v, want %v", got, want)
	}
}

func TestWriteTTFTTooSlowSets429RetryAfter(t *testing.T) {
	srv, _ := testServer(t)
	threshold := srv.FirstContentDeadline("slow-ttft-model", 0)
	if threshold != 5*time.Second {
		t.Fatalf("FirstContentDeadline(0) = %v, want 5s", threshold)
	}
	// The 3 s overage floors the answer; the shared source then adds 0..50%
	// jitter (retry_after.go), so the answer lands in [3, 4].
	if got := srv.estimateTTFTRetryAfter("no-queue", "", 8*time.Second, threshold); got < 3 || got > 4 {
		t.Fatalf("Retry-After without queue = %d, want within [3, 4] (3s over target + jitter)", got)
	}

	model := "slow-ttft-model"
	for i := 0; i < 5; i++ {
		if err := srv.registry.Queue().Enqueue(&registry.QueuedRequest{RequestID: "queued-" + strconv.Itoa(i), Model: model}); err != nil {
			t.Fatal(err)
		}
	}

	w := httptest.NewRecorder()
	srv.writeTTFTTooSlow(w, "", model, model, 6*time.Second, threshold)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusTooManyRequests)
	}
	// Five queued: legacy base 15 s, jittered to [15, 22].
	if got, err := strconv.Atoi(w.Header().Get("Retry-After")); err != nil || got < 15 || got > 22 {
		t.Fatalf("Retry-After = %q, want within [15, 22] from the queue-depth estimate + jitter", w.Header().Get("Retry-After"))
	}
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if body.Error.Code != "rate_limit_exceeded" {
		t.Fatalf("code = %q, want rate_limit_exceeded", body.Error.Code)
	}
	if !strings.Contains(body.Error.Message, "5s TTFT target") {
		t.Fatalf("message = %q, want TTFT target detail", body.Error.Message)
	}
}

func TestTTFTAdmission429BelowOldTenSecondFloor(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetTTFTHardReject(true) // legacy hard 429-on-slow-estimate path (now opt-in)
	model := "exact-ttft-floor-model"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})
	p := registerBuildsProvider(srv, "exact-floor-provider", model)
	p.Mu().Lock()
	p.DecodeTPS = 100
	p.PrefillTPS = 0.2 // 1 input token => ~5s prefill + first decode, above exact 5.001s target but below old 10s floor.
	p.Mu().Unlock()

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(
		strings.ReplaceAll(`{"model":"MODEL","input":"hello","max_output_tokens":128}`, "MODEL", model)))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want %d; body = %s", w.Code, http.StatusTooManyRequests, w.Body.String())
	}
	if got := w.Header().Get("Retry-After"); got == "" {
		t.Fatal("Retry-After header missing")
	}
}

func TestTTFTAdmission429ForInferenceEndpoints(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetTTFTHardReject(true) // legacy hard 429-on-slow-estimate path (now opt-in)
	model := "route-slow-ttft-model"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})
	p := registerBuildsProvider(srv, "route-slow-provider", model)
	p.Mu().Lock()
	p.DecodeTPS = 100
	p.PrefillTPS = 400
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	p.Mu().Unlock()

	cases := []struct {
		name string
		path string
		body string
	}{
		{
			name: "responses-style chat completions",
			path: "/v1/chat/completions",
			body: `{"model":"MODEL","input":"hello","max_output_tokens":128}`,
		},
		{
			name: "completions",
			path: "/v1/completions",
			body: `{"model":"MODEL","prompt":"hello","max_tokens":128}`,
		},
		{
			name: "anthropic messages",
			path: "/v1/messages",
			body: `{"model":"MODEL","messages":[{"role":"user","content":"hello"}],"max_tokens":128}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, tc.path, strings.NewReader(strings.ReplaceAll(tc.body, "MODEL", model)))
			req.Header.Set("Authorization", "Bearer test-key")
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusTooManyRequests {
				t.Fatalf("status = %d, want %d; body = %s", w.Code, http.StatusTooManyRequests, w.Body.String())
			}
			if got := w.Header().Get("Retry-After"); got == "" {
				t.Fatal("Retry-After header missing")
			}
			var body struct {
				Error struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if body.Error.Code != "rate_limit_exceeded" {
				t.Fatalf("code = %q, want rate_limit_exceeded", body.Error.Code)
			}
			// Assert the TTFT preflight path specifically (not a capacity 429),
			// so this test exercises the hard TTFT gate it is named for.
			if !strings.Contains(body.Error.Message, "TTFT target") {
				t.Fatalf("message = %q, want TTFT target detail", body.Error.Message)
			}
		})
	}
}

// TestTTFTSoftGateDoesNotShedAtDispatch is the regression for the Codex P1: in
// the default SOFT gate, an over-deadline request must not be rejected as
// ttft_too_slow — not at the preflight AND not (the bug) at dispatch via a
// non-zero pr.MaxTTFTMs causing ReserveProviderEx to drop every candidate. With
// a single eligible provider and no capacity pressure, the only possible 429 is
// the TTFT shed, so asserting "not 429" pins the fix. (The request can't truly
// stream over a nil test conn — its dead writer resolves to the send-failed
// ladder's own 429, "no provider accepted the request", which is not a TTFT
// rejection; it just must never be ttft-rejected.)
func TestTTFTSoftGateDoesNotShedAtDispatch(t *testing.T) {
	srv, _ := testServer(t) // default: soft gate (ttftHardReject=false)
	model := "soft-serve-ttft-model"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})
	p := registerBuildsProvider(srv, "slow-prefill-provider", model)
	p.Mu().Lock()
	p.DecodeTPS = 100
	p.PrefillTPS = 0.2 // ~5s prefill even for a tiny prompt => TTFT estimate >> deadline
	p.Mu().Unlock()

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(
		strings.ReplaceAll(`{"model":"MODEL","messages":[{"role":"user","content":"hello"}],"max_tokens":16}`, "MODEL", model)))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code == http.StatusTooManyRequests && !strings.Contains(w.Body.String(), "no provider accepted the request") {
		t.Fatalf("soft gate shed an over-deadline request with 429 (P1 regression); body=%s", w.Body.String())
	}
	if strings.Contains(w.Body.String(), "TTFT target") || strings.Contains(w.Body.String(), "temporarily rate-limited") {
		t.Fatalf("soft gate shed an over-deadline request (P1 regression); body=%s", w.Body.String())
	}
}

func TestTTFTHardGateDoesNotRejectMediaOnTextOnlyEstimate(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetTTFTHardReject(true)
	warmCfg := registry.ReadConfig().WarmPool
	warmCfg.Enabled = true
	warmCfg.ObserveOnly = false
	srv.registry.ConfigureWarmPool(warmCfg)
	model := "media-estimate-is-partial"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})
	srv.registry.RecordWarmPoolSpeculativeStarted(model) // seed an observable bucket
	p := registerBuildsProvider(srv, "vision-provider", model)
	p.Mu().Lock()
	p.DecodeTPS = 100
	p.PrefillTPS = 0.2
	p.Models[0].IsVision = true
	p.Mu().Unlock()

	body := strings.ReplaceAll(
		`{"model":"MODEL","messages":[{"role":"user","content":[{"type":"text","text":"describe"},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgo="}}]}],"max_tokens":16}`,
		"MODEL", model)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	// The nil test conn resolves to the send-failed ladder's own 429 ("no
	// provider accepted the request"); only a TTFT-shaped rejection fails
	// this — by vocabulary, and by status for a hard-gate regression that
	// drops every candidate and surfaces as a generic capacity 429 without
	// the TTFT wording (the sibling soft-gate test keeps the same scoped
	// status check).
	if w.Code == http.StatusTooManyRequests && !strings.Contains(w.Body.String(), "no provider accepted the request") {
		t.Fatalf("hard gate shed media on a text-only estimate with 429; body=%s", w.Body.String())
	}
	if strings.Contains(w.Body.String(), "TTFT target") || strings.Contains(w.Body.String(), "temporarily rate-limited") {
		t.Fatalf("hard gate used a text-only estimate to reject media: status=%d body=%s", w.Code, w.Body.String())
	}
	found := false
	for _, snap := range srv.registry.TriggerWarmPool() {
		if snap.Model != model {
			continue
		}
		found = true
		if snap.TTFTMisses != 0 {
			t.Fatalf("media token proxy emitted %d synthetic warm-pool TTFT miss(es), want 0", snap.TTFTMisses)
		}
	}
	if !found {
		t.Fatal("warm-pool snapshot missing media model")
	}
}

func TestMaybeFallbackAliasTTFTSwitchesToPrevious(t *testing.T) {
	srv, _ := testServer(t)
	publicModel := "public-ttft-alias"
	desired := "desired-ttft-build"
	previous := "previous-ttft-build"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: desired, SizeGB: 1, MinRAMGB: 24},
		{ID: previous, SizeGB: 1, MinRAMGB: 24},
	})
	srv.registry.SetModelAliases(map[string]registry.AliasTarget{
		publicModel: {Desired: desired, Previous: previous},
	})

	desiredProvider := registerBuildsProvider(srv, "desired-slow", desired)
	desiredProvider.Mu().Lock()
	desiredProvider.DecodeTPS = 100
	desiredProvider.PrefillTPS = 400
	desiredProvider.BackendCapacity.Slots[0].State = "idle_shutdown"
	desiredProvider.Mu().Unlock()

	previousProvider := registerBuildsProvider(srv, "previous-fast", previous)
	previousProvider.Mu().Lock()
	previousProvider.DecodeTPS = 100
	previousProvider.PrefillTPS = 400
	previousProvider.Mu().Unlock()

	parsed := map[string]any{"model": desired}
	fallbackModel, candidates, rejections, tooLarge, bestTTFT, hasTTFT, switched := srv.maybeFallbackAlias(
		parsed,
		aliasFallbackTTFT,
		publicModel,
		desired,
		100,
		128,
		srv.FirstContentDeadline(desired, 100),
		registry.RequestTraits{},
		false,
		nil,
	)

	if !switched {
		t.Fatalf("switched = false, candidates=%d rejections=%d tooLarge=%d bestTTFT=%v has=%v", candidates, rejections, tooLarge, bestTTFT, hasTTFT)
	}
	if fallbackModel != previous || parsed["model"] != previous {
		t.Fatalf("fallback model = %q parsed=%v, want previous %q", fallbackModel, parsed["model"], previous)
	}
	if candidates != 1 || rejections != 0 || tooLarge != 0 {
		t.Fatalf("capacity = (%d,%d,%d), want (1,0,0)", candidates, rejections, tooLarge)
	}
	if !hasTTFT || bestTTFT > srv.FirstContentDeadline(desired, 100) {
		t.Fatalf("bestTTFT = %v has=%v, want within threshold", bestTTFT, hasTTFT)
	}

	// Alias fallback must consume the logical request's pinned deadline rather
	// than recomputing a fresh full duration for Previous. A deliberately tiny
	// pinned budget therefore blocks the same otherwise-healthy fallback.
	parsed["model"] = desired
	fallbackModel, _, _, _, _, _, switched = srv.maybeFallbackAlias(
		parsed,
		aliasFallbackTTFT,
		publicModel,
		desired,
		100,
		128,
		time.Nanosecond,
		registry.RequestTraits{},
		false,
		nil,
	)
	if switched || fallbackModel != previous || parsed["model"] != desired {
		t.Fatalf("expired pinned deadline restarted on Previous: switched=%v fallback=%q parsed=%v", switched, fallbackModel, parsed)
	}
}

func TestMaybeFallbackAliasTTFTSkipsRejectedPrevious(t *testing.T) {
	srv, _ := testServer(t)
	publicModel := "public-ttft-shed-alias"
	desired := "desired-ttft-shed-build"
	previous := "previous-ttft-shed-build"
	srv.SetRejectModels(map[string]bool{previous: true})
	srv.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: desired, SizeGB: 1, MinRAMGB: 24},
		{ID: previous, SizeGB: 1, MinRAMGB: 24},
	})
	srv.registry.SetModelAliases(map[string]registry.AliasTarget{
		publicModel: {Desired: desired, Previous: previous},
	})
	registerBuildsProvider(srv, "previous-fast-shed", previous)
	parsed := map[string]any{"model": desired}

	fallbackModel, _, _, _, _, _, switched := srv.maybeFallbackAlias(
		parsed, aliasFallbackTTFT, publicModel, desired, 100, 128, srv.FirstContentDeadline(desired, 100), registry.RequestTraits{}, false, nil)

	if switched || fallbackModel != desired || parsed["model"] != desired {
		t.Fatalf("fallback switched to rejected previous: switched=%v fallback=%q parsed=%v", switched, fallbackModel, parsed)
	}
}

func TestMaybeFallbackAliasCapacitySkipsRejectedPrevious(t *testing.T) {
	srv, _ := testServer(t)
	publicModel := "public-capacity-shed-alias"
	desired := "desired-capacity-shed-build"
	previous := "previous-capacity-shed-build"
	srv.SetRejectModels(map[string]bool{previous: true})
	srv.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: desired, SizeGB: 1, MinRAMGB: 24},
		{ID: previous, SizeGB: 1, MinRAMGB: 24},
	})
	srv.registry.SetModelAliases(map[string]registry.AliasTarget{
		publicModel: {Desired: desired, Previous: previous},
	})
	registerBuildsProvider(srv, "previous-capacity-shed", previous)
	parsed := map[string]any{"model": desired}

	fallbackModel, _, _, _, _, _, switched := srv.maybeFallbackAlias(
		parsed, aliasFallbackCapacity, publicModel, desired, 100, 128, 0, registry.RequestTraits{}, false, nil)

	if switched || fallbackModel != desired || parsed["model"] != desired {
		t.Fatalf("capacity fallback switched to rejected previous: switched=%v fallback=%q parsed=%v", switched, fallbackModel, parsed)
	}
}

// TestFirstContentDeadlineCountsToolSchemas pins the T10-07 product effect on
// the first-content clock: a 6 KB tools array adds 1,536 estimated prompt
// tokens, and at the fixed 1 ms/token slope the deadline widens by exactly
// 1.536 s — the budget an agentic request's schema-heavy prefill was silently
// missing. Tool-less requests are unchanged.
func TestFirstContentDeadlineCountsToolSchemas(t *testing.T) {
	srv, _ := testServer(t)
	const model = "tools-deadline-model"
	body := map[string]any{"model": model, "messages": []any{map[string]any{"role": "user", "content": "hello"}}}
	base := srv.FirstContentDeadline(model, estimatePromptTokens(body))
	if base != 5*time.Second+5*time.Millisecond {
		t.Fatalf("tool-less deadline = %v, want 5.005s", base)
	}
	body["tools"] = toolSchemaOfJSONLength(t, 6144)
	if got, want := srv.FirstContentDeadline(model, estimatePromptTokens(body)), base+1536*time.Millisecond; got != want {
		t.Fatalf("deadline with 6 KB tools = %v, want %v (+1.536s)", got, want)
	}
}
