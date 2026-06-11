package e2e

// PR #311 — OpenAI API compatibility fixes, end-to-end against a REAL MLX model.
//
// These tests boot the full stack (coordinator built from the PR branch + real
// Swift provider + real local model) and exercise every consumer-facing behavior
// the PR claims to fix. The PR authors only tested against the live prod
// coordinator from Linux containers; this closes the "did anyone actually run a
// real provider through it?" gap.
//
// Run:
//   RUN_PR311=1 \
//   DARKBLOOM_REPO_ROOT=/Users/gaj/Documents/Builds/d-inference \
//   TESTBED_MODEL_ID=mlx-community/gpt-oss-20b-MXFP4-Q8 \
//   go test ./e2e/ -run TestPR311 -v -timeout 30m
//
// DARKBLOOM_REPO_ROOT must point at a checkout whose
// provider-swift/.build/release/ has both `darkbloom` and `mlx.metallib`, so the
// testbed uses the cached binary instead of rebuilding.

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
)

const pr311AdminKey = "testbed-admin-key"

func pr311Skip(t *testing.T) {
	if os.Getenv("RUN_PR311") == "" {
		t.Skip("set RUN_PR311=1 to run the PR #311 real-model OpenAI-compat suite")
	}
}

// pr311Post sends a JSON body to an absolute path on the coordinator.
func pr311Post(t *testing.T, s *testbed.Suite, path string, body map[string]any) *http.Response {
	t.Helper()
	raw, err := json.Marshal(body)
	require.NoError(t, err)
	req, err := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		s.Coordinator.BaseURL()+path, strings.NewReader(string(raw)))
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer "+pr311AdminKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 300 * time.Second}).Do(req)
	require.NoError(t, err)
	return resp
}

func pr311Get(t *testing.T, s *testbed.Suite, path string) *http.Response {
	t.Helper()
	req, err := http.NewRequestWithContext(s.Ctx, http.MethodGet, s.Coordinator.BaseURL()+path, nil)
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer "+pr311AdminKey)
	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	require.NoError(t, err)
	return resp
}

func decodeJSON(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal(raw, &m), "body was: %s", string(raw))
	return m
}

type sseEvent struct {
	Event string
	Data  string
}

// readSSE reads a full SSE stream into ordered events. It captures both the
// optional `event:` line (Responses API) and the `data:` payload (both APIs).
func readSSE(t *testing.T, resp *http.Response) []sseEvent {
	t.Helper()
	defer resp.Body.Close()
	var events []sseEvent
	var cur sseEvent
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 0, 1024*1024), 8*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case line == "":
			if cur.Data != "" || cur.Event != "" {
				events = append(events, cur)
				cur = sseEvent{}
			}
		case strings.HasPrefix(line, "event:"):
			cur.Event = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		case strings.HasPrefix(line, "data:"):
			d := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			if cur.Data == "" {
				cur.Data = d
			} else {
				cur.Data += "\n" + d
			}
		}
	}
	if cur.Data != "" || cur.Event != "" {
		events = append(events, cur)
	}
	return events
}

// chatChunk is the minimal shape of a streaming chat.completion.chunk.
type chatChunk struct {
	Choices []struct {
		Delta        map[string]any `json:"delta"`
		FinishReason *string        `json:"finish_reason"`
	} `json:"choices"`
	Usage *struct {
		CompletionTokens int `json:"completion_tokens"`
		PromptTokens     int `json:"prompt_tokens"`
	} `json:"usage"`
}

func providerPID(t *testing.T) int {
	t.Helper()
	raw, err := os.ReadFile("/tmp/darkbloom-testbed-0.pid")
	require.NoError(t, err, "provider pid file missing")
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	require.NoError(t, err)
	return pid
}

// TestPR311_OpenAICompat boots the stack once and runs every behavior as a subtest.
func TestPR311_OpenAICompat(t *testing.T) {
	pr311Skip(t)

	model := os.Getenv("TESTBED_MODEL_ID")
	if model == "" {
		model = "mlx-community/gpt-oss-20b-MXFP4-Q8"
	}
	t.Logf("PR #311 real-model suite — model=%s", model)

	ctx := context.Background()
	s := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs:     []testbed.ModelSpec{{ModelID: model, NumProviders: 1}},
		NumUsers:       1,
		UseMemoryStore: true,
		SeedBalance:    1_000_000_000,
	})
	require.NoError(t, s.Start(ctx), "suite startup failed")
	t.Cleanup(s.Stop)
	model = s.PrimaryModelID()

	// Sanity: the stack actually serves the model before we assert subtleties.
	t.Run("Sanity_NonStreaming", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/chat/completions", map[string]any{
			"model":       model,
			"messages":    []map[string]string{{"role": "user", "content": "Reply with exactly: OK"}},
			"max_tokens":  32,
			"temperature": 0.0,
		})
		require.Equal(t, 200, resp.StatusCode)
		body := decodeJSON(t, resp)
		choices, _ := body["choices"].([]any)
		require.NotEmpty(t, choices, "no choices: %v", body)
		t.Logf("sanity reply ok; usage=%v", body["usage"])
	})

	// FIX 1a: finish_reason="length" when generation hits the max-tokens bound (non-streaming).
	t.Run("FinishReason_Length_NonStreaming", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/chat/completions", map[string]any{
			"model":       model,
			"messages":    []map[string]string{{"role": "user", "content": "Count slowly from 1 to 500, one number per line."}},
			"max_tokens":  16,
			"temperature": 0.0,
		})
		require.Equal(t, 200, resp.StatusCode)
		body := decodeJSON(t, resp)
		choices := body["choices"].([]any)
		c0 := choices[0].(map[string]any)
		fr, _ := c0["finish_reason"].(string)
		usage, _ := body["usage"].(map[string]any)
		assert.Equal(t, "length", fr, "truncated generation must report finish_reason=length; usage=%v", usage)
	})

	// FIX 1b: finish_reason="stop" on a natural completion (no false-positive "length").
	t.Run("FinishReason_Stop_NonStreaming", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/chat/completions", map[string]any{
			"model":       model,
			"messages":    []map[string]string{{"role": "user", "content": "Reply with exactly one word: hello"}},
			"max_tokens":  256,
			"temperature": 0.0,
		})
		require.Equal(t, 200, resp.StatusCode)
		body := decodeJSON(t, resp)
		c0 := body["choices"].([]any)[0].(map[string]any)
		fr, _ := c0["finish_reason"].(string)
		assert.Equal(t, "stop", fr, "short natural completion must report finish_reason=stop, not length")
	})

	// FIX 1c: finish_reason="length" on the STREAMING path + correct emit order
	// (finish chunk -> usage chunk -> [DONE]).
	t.Run("FinishReason_Length_Streaming", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/chat/completions", map[string]any{
			"model":          model,
			"messages":       []map[string]string{{"role": "user", "content": "Count slowly from 1 to 500, one number per line."}},
			"max_tokens":     16,
			"temperature":    0.0,
			"stream":         true,
			"stream_options": map[string]any{"include_usage": true},
		})
		require.Equal(t, 200, resp.StatusCode)
		events := readSSE(t, resp)
		require.NotEmpty(t, events)

		var lastFinish string
		var finishIdx, usageIdx, doneIdx = -1, -1, -1
		for i, ev := range events {
			if ev.Data == "[DONE]" {
				doneIdx = i
				continue
			}
			var ch chatChunk
			if err := json.Unmarshal([]byte(ev.Data), &ch); err != nil {
				continue
			}
			if len(ch.Choices) > 0 && ch.Choices[0].FinishReason != nil {
				lastFinish = *ch.Choices[0].FinishReason
				finishIdx = i
			}
			if ch.Usage != nil && len(ch.Choices) == 0 {
				usageIdx = i
			}
		}
		assert.Equal(t, "length", lastFinish, "streaming truncation must report finish_reason=length")
		assert.GreaterOrEqual(t, doneIdx, 0, "[DONE] terminator must be present")
		if finishIdx >= 0 && doneIdx >= 0 {
			assert.Less(t, finishIdx, doneIdx, "finish chunk must precede [DONE]")
		}
		if finishIdx >= 0 && usageIdx >= 0 {
			assert.Less(t, finishIdx, usageIdx, "finish chunk must precede usage chunk")
			assert.Less(t, usageIdx, doneIdx, "usage chunk must precede [DONE]")
		}
	})

	// FIX 2: max_completion_tokens (OpenAI's newer field) is normalized to max_tokens
	// so the bound actually reaches the engine — proven by truncation at the bound.
	t.Run("MaxCompletionTokens_Alias_Honored", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/chat/completions", map[string]any{
			"model":                 model,
			"messages":              []map[string]string{{"role": "user", "content": "Count slowly from 1 to 500, one number per line."}},
			"max_completion_tokens": 16,
			"temperature":           0.0,
		})
		require.Equal(t, 200, resp.StatusCode)
		body := decodeJSON(t, resp)
		c0 := body["choices"].([]any)[0].(map[string]any)
		fr, _ := c0["finish_reason"].(string)
		usage, _ := body["usage"].(map[string]any)
		assert.Equal(t, "length", fr, "max_completion_tokens must bound generation; usage=%v", usage)
		if usage != nil {
			if ct, ok := usage["completion_tokens"].(float64); ok {
				assert.LessOrEqual(t, int(ct), 24, "completion_tokens should be ~16, got %v", ct)
			}
		}
	})

	// FIX 3a: n>1 rejected with 400 on chat completions.
	t.Run("N_GT1_Chat_400", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/chat/completions", map[string]any{
			"model":      model,
			"messages":   []map[string]string{{"role": "user", "content": "hi"}},
			"max_tokens": 16,
			"n":          2,
		})
		assert.Equal(t, 400, resp.StatusCode, "n>1 must be rejected with 400")
		body := decodeJSON(t, resp)
		t.Logf("n>1 chat error body: %v", body["error"])
	})

	// FIX 3b: resolve reviewer disagreement — does the n>1 guard also cover /v1/responses?
	t.Run("N_GT1_Responses_Behavior", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/responses", map[string]any{
			"model": model,
			"input": "hi",
			"n":     2,
		})
		body := decodeJSON(t, resp)
		t.Logf("n>1 on /v1/responses -> status=%d body.error=%v", resp.StatusCode, body["error"])
		// Documented as a finding either way; chat path is the contract. We assert
		// it does NOT 500 (a crash would be a real bug).
		assert.NotEqual(t, 500, resp.StatusCode, "n>1 on responses must not 500")
	})

	// FIX 4a: GET /v1/models/{id} retrieve-model, including slashed HF ids.
	t.Run("GetModelByID", func(t *testing.T) {
		resp := pr311Get(t, s, "/v1/models/"+model)
		require.Equal(t, 200, resp.StatusCode, "retrieve model by id must be 200")
		body := decodeJSON(t, resp)
		assert.Equal(t, "model", body["object"], "retrieve must return an OpenAI model object")
		assert.Equal(t, model, body["id"], "retrieved id must echo the requested id")
	})

	// FIX 4b: literal /v1/models/* routes must still win over the {id...} wildcard.
	t.Run("ModelsLiteralRoutesWin", func(t *testing.T) {
		// /v1/models (list) must return a list, not a single model object.
		listResp := pr311Get(t, s, "/v1/models")
		require.Equal(t, 200, listResp.StatusCode)
		list := decodeJSON(t, listResp)
		assert.Equal(t, "list", list["object"], "/v1/models must be the list endpoint")

		// /v1/models/openrouter must NOT be swallowed by the wildcard as id="openrouter".
		orResp := pr311Get(t, s, "/v1/models/openrouter")
		if orResp.StatusCode == 200 {
			or := decodeJSON(t, orResp)
			if or["object"] == "model" && or["id"] == "openrouter" {
				t.Errorf("/v1/models/openrouter was shadowed by the {id} wildcard")
			}
		} else {
			orResp.Body.Close()
		}

		// Unknown id must 404 (model_not_found), not 200.
		nfResp := pr311Get(t, s, "/v1/models/this-model-does-not-exist-xyz")
		assert.Equal(t, 404, nfResp.StatusCode, "unknown model id must 404")
		nfResp.Body.Close()
	})

	// FIX 5a: Responses API non-streaming envelope — spec-required fields + completed status.
	t.Run("Responses_NonStreaming_Envelope", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/responses", map[string]any{
			"model":             model,
			"input":             "Reply with exactly one word: hello",
			"max_output_tokens": 200,
		})
		require.Equal(t, 200, resp.StatusCode)
		body := decodeJSON(t, resp)
		assert.Equal(t, "response", body["object"])
		assert.Equal(t, "completed", body["status"], "short completion -> status completed")

		// Spec-required envelope keys the PR adds (presence; nulls allowed).
		for _, k := range []string{"error", "incomplete_details", "instructions", "metadata",
			"parallel_tool_calls", "tool_choice", "tools", "top_p", "temperature",
			"max_output_tokens", "model", "output", "usage", "created_at", "id"} {
			_, ok := body[k]
			assert.True(t, ok, "responses envelope missing required key %q", k)
		}

		// Output items must carry status=completed and contain assistant text.
		output, _ := body["output"].([]any)
		require.NotEmpty(t, output, "responses output must be non-empty")
		var sawText bool
		for _, it := range output {
			item, _ := it.(map[string]any)
			if item["type"] == "message" {
				assert.Equal(t, "completed", item["status"], "message item status")
				content, _ := item["content"].([]any)
				for _, p := range content {
					part, _ := p.(map[string]any)
					if txt, ok := part["text"].(string); ok && strings.TrimSpace(txt) != "" {
						sawText = true
					}
				}
			}
		}
		assert.True(t, sawText, "responses output must contain assistant text")
	})

	// FIX 5b: Responses non-streaming truncation -> status incomplete + incomplete_details.
	t.Run("Responses_NonStreaming_Truncation_Incomplete", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/responses", map[string]any{
			"model":             model,
			"input":             "Count slowly from 1 to 500, one number per line.",
			"max_output_tokens": 16,
		})
		require.Equal(t, 200, resp.StatusCode)
		body := decodeJSON(t, resp)
		assert.Equal(t, "incomplete", body["status"], "truncated responses must be status=incomplete")
		det, _ := body["incomplete_details"].(map[string]any)
		require.NotNil(t, det, "incomplete_details must be present on truncation")
		assert.Equal(t, "max_output_tokens", det["reason"])
	})

	// FIX 6a: Responses API streaming emits real incremental events in spec order.
	t.Run("Responses_Streaming_Events", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/responses", map[string]any{
			"model":             model,
			"input":             "Reply with exactly one word: hello",
			"max_output_tokens": 200,
			"stream":            true,
		})
		require.Equal(t, 200, resp.StatusCode)
		events := readSSE(t, resp)
		require.NotEmpty(t, events)

		var types []string
		var seqs []float64
		var sawTextDelta bool
		var terminal string
		for _, ev := range events {
			var d map[string]any
			if err := json.Unmarshal([]byte(ev.Data), &d); err == nil {
				if sn, ok := d["sequence_number"].(float64); ok {
					seqs = append(seqs, sn)
				}
				if tp, ok := d["type"].(string); ok {
					types = append(types, tp)
					if tp == "response.output_text.delta" {
						sawTextDelta = true
					}
					if strings.HasPrefix(tp, "response.completed") || strings.HasPrefix(tp, "response.incomplete") {
						terminal = tp
					}
				}
			}
		}
		t.Logf("responses stream event types: %v", types)
		assert.Contains(t, types, "response.created", "must emit response.created first")
		assert.Contains(t, types, "response.output_item.added")
		assert.True(t, sawTextDelta, "must emit at least one output_text.delta")
		assert.Contains(t, types, "response.output_item.done")
		assert.Contains(t, []string{"response.completed", "response.incomplete"}, terminal,
			"stream must end with a terminal response event, got %q", terminal)
		// sequence_number monotonic
		for i := 1; i < len(seqs); i++ {
			assert.GreaterOrEqual(t, seqs[i], seqs[i-1], "sequence_number must be monotonic")
		}
	})

	// FIX 6b: Responses streaming truncation -> terminal event response.incomplete.
	t.Run("Responses_Streaming_Truncation_Incomplete", func(t *testing.T) {
		resp := pr311Post(t, s, "/v1/responses", map[string]any{
			"model":             model,
			"input":             "Count slowly from 1 to 500, one number per line.",
			"max_output_tokens": 16,
			"stream":            true,
		})
		require.Equal(t, 200, resp.StatusCode)
		events := readSSE(t, resp)
		var terminal string
		for _, ev := range events {
			var d map[string]any
			if err := json.Unmarshal([]byte(ev.Data), &d); err == nil {
				if tp, ok := d["type"].(string); ok {
					if tp == "response.completed" || tp == "response.incomplete" {
						terminal = tp
					}
				}
			}
		}
		assert.Equal(t, "response.incomplete", terminal, "truncated responses stream must end with response.incomplete")
	})

	// REGRESSION PROBE (Codex HIGH): provider disconnect mid Responses-stream.
	// Codex claimed the 2s CompleteCh-timeout path can emit a success-looking
	// response.completed with zero usage instead of an error. Kill the provider
	// mid-generation and record what the client actually receives. MUST RUN LAST
	// (it kills the only provider).
	t.Run("ZZ_ProviderDisconnect_Responses_Streaming", func(t *testing.T) {
		pid := providerPID(t)
		req, err := http.NewRequestWithContext(s.Ctx, http.MethodPost,
			s.Coordinator.BaseURL()+"/v1/responses", strings.NewReader(`{"model":"`+model+`","input":"Write a very long, detailed 1000-word essay about the history of computing.","max_output_tokens":2000,"stream":true}`))
		require.NoError(t, err)
		req.Header.Set("Authorization", "Bearer "+pr311AdminKey)
		req.Header.Set("Content-Type", "application/json")
		resp, err := (&http.Client{Timeout: 120 * time.Second}).Do(req)
		require.NoError(t, err)
		defer resp.Body.Close()

		sc := bufio.NewScanner(resp.Body)
		sc.Buffer(make([]byte, 0, 1024*1024), 8*1024*1024)
		var types []string
		killed := false
		deltas := 0
		for sc.Scan() {
			line := sc.Text()
			if strings.HasPrefix(line, "data:") {
				d := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
				var m map[string]any
				if json.Unmarshal([]byte(d), &m) == nil {
					if tp, ok := m["type"].(string); ok {
						types = append(types, tp)
						if tp == "response.output_text.delta" {
							deltas++
							// Kill the provider after generation is clearly underway.
							if deltas == 2 && !killed {
								_ = syscall.Kill(pid, syscall.SIGKILL)
								killed = true
								t.Logf("SIGKILLed provider pid=%d mid-stream after %d deltas", pid, deltas)
							}
						}
					}
				}
			}
		}
		scanErr := sc.Err()
		terminal := ""
		if len(types) > 0 {
			terminal = types[len(types)-1]
		}
		t.Logf("after provider kill: total_events=%d deltas=%d terminal=%q scanErr=%v",
			len(types), deltas, terminal, scanErr)
		require.True(t, killed, "test precondition: provider must have been killed mid-stream")

		switch {
		case terminal == "response.completed":
			t.Errorf("REGRESSION (Codex HIGH confirmed): client received success-looking %q after provider crash — error was masked", terminal)
		case terminal == "response.incomplete":
			t.Logf("acceptable: terminal=response.incomplete after crash (truncation-shaped, not a success)")
		case terminal == "error" || strings.Contains(terminal, "error"):
			t.Logf("GOOD: client received an error event after provider crash (terminal=%q)", terminal)
		default:
			t.Logf("client stream ended without a success terminal (terminal=%q, scanErr=%v) — acceptable (no masked success)", terminal, scanErr)
		}
	})
}
