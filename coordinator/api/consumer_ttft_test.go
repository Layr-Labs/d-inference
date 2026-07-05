package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWriteServiceUnavailableSetsRetryAfter(t *testing.T) {
	srv, _ := testServer(t)
	w := httptest.NewRecorder()
	srv.writeServiceUnavailable(w, "gpt-oss-20b")

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
	tests := []struct {
		inputTokens int
		want        time.Duration
	}{
		{inputTokens: 0, want: 5 * time.Second},
		{inputTokens: 1, want: 5*time.Second + time.Millisecond},
		{inputTokens: 5_000, want: 10 * time.Second},
		{inputTokens: 5_001, want: 10*time.Second + time.Millisecond},
	}

	for _, tt := range tests {
		if got := ttftDeadline(tt.inputTokens); got != tt.want {
			t.Fatalf("ttftDeadline(%d) = %v, want %v", tt.inputTokens, got, tt.want)
		}
	}
}

func TestWriteTTFTTooSlowSets429RetryAfter(t *testing.T) {
	srv, _ := testServer(t)
	threshold := ttftDeadline(0)
	if threshold != 5*time.Second {
		t.Fatalf("ttftDeadline(0) = %v, want 5s", threshold)
	}
	if got := srv.estimateTTFTRetryAfter("no-queue", 8*time.Second, threshold); got != 3 {
		t.Fatalf("Retry-After without queue = %d, want 3s over target", got)
	}

	model := "slow-ttft-model"
	for i := 0; i < 5; i++ {
		if err := srv.registry.Queue().Enqueue(&registry.QueuedRequest{RequestID: "queued-" + strconv.Itoa(i), Model: model}); err != nil {
			t.Fatal(err)
		}
	}

	w := httptest.NewRecorder()
	srv.writeTTFTTooSlow(w, model, model, 6*time.Second, threshold)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusTooManyRequests)
	}
	if got := w.Header().Get("Retry-After"); got != "15" {
		t.Fatalf("Retry-After = %q, want 15 from existing queue-depth estimate", got)
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
// stream over a nil test conn; it just must never be ttft-rejected.)
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

	if w.Code == http.StatusTooManyRequests {
		t.Fatalf("soft gate shed an over-deadline request with 429 (P1 regression); body=%s", w.Body.String())
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
		ttftDeadline(100),
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
	if !hasTTFT || bestTTFT > ttftDeadline(100) {
		t.Fatalf("bestTTFT = %v has=%v, want within threshold", bestTTFT, hasTTFT)
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
		parsed, aliasFallbackTTFT, publicModel, desired, 100, 128, ttftDeadline(100), registry.RequestTraits{}, false, nil)

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
