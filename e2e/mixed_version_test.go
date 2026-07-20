package e2e

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
)

func TestIntegrationMixedVersionReleasedV0710Provider(t *testing.T) {
	if os.Getenv("DARKBLOOM_MIXED_VERSION") != "1" {
		t.Skip("set DARKBLOOM_MIXED_VERSION=1 with the verified v0.7.10 binary")
	}
	if output, err := exec.Command("/usr/bin/csrutil", "status").CombinedOutput(); err != nil || !strings.Contains(string(output), "status: enabled") {
		t.Skip("released v0.7.10 enforces SIP; this runner cannot execute it")
	}
	require.NotEmpty(t, os.Getenv("DARKBLOOM_PROVIDER_BINARY"))
	t.Setenv("DARKBLOOM_CBV2_MTP", "0")
	t.Setenv("DARKBLOOM_PREFIX_CACHE", "0")

	suite := testbed.NewSuite(testbed.SuiteConfig{})
	require.NoError(t, suite.Start(t.Context()))
	t.Cleanup(suite.Stop)
	providers := liveProviders(suite.Coordinator.Registry)
	require.NotEmpty(t, providers)
	providers[0].Mu().Lock()
	version := providers[0].Version
	cacheProtocol := providers[0].PrefixCacheProtocol
	toolConstraintProtocol := providers[0].ToolConstraintProtocol
	providers[0].Mu().Unlock()
	require.Equal(t, "0.7.10", version)
	require.Less(t, cacheProtocol, 2, "released provider unexpectedly advertised candidate protocol v2")
	require.Zero(t, toolConstraintProtocol,
		"released provider unexpectedly advertised inference-time tool constraints")

	model := suite.PrimaryModelID()
	tool := map[string]any{
		"type": "function",
		"function": map[string]any{
			"name":        "lookup_weather",
			"description": "Look up weather.",
			"parameters": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"city": map[string]any{"type": "string"},
				},
			},
		},
	}
	cases := []struct {
		name, endpoint string
		body           map[string]any
		required       []string
	}{
		{
			name: "chat_completions", endpoint: "/v1/chat/completions",
			body: map[string]any{
				"model": model, "messages": []map[string]string{{"role": "user", "content": "Reply with OK."}},
				"max_tokens": 16, "temperature": 0, "stop": []string{"END"},
				"tools": []any{tool}, "tool_choice": "auto",
			},
			required: []string{`"choices"`, `"message"`},
		},
		{
			name: "completions", endpoint: "/v1/completions",
			body: map[string]any{
				"model": model, "prompt": "Reply with OK.", "max_tokens": 16,
				"temperature": 0, "stop": []string{"END"},
			},
			required: []string{`"choices"`, `"text"`},
		},
		{
			name: "responses", endpoint: "/v1/responses",
			body: map[string]any{
				"model": model, "input": "Reply with OK.", "max_output_tokens": 16,
				"temperature": 0, "tools": []any{tool}, "tool_choice": "auto",
			},
			required: []string{`"object":"response"`, `"output"`},
		},
		{
			name: "messages", endpoint: "/v1/messages",
			body: map[string]any{
				"model": model, "messages": []map[string]string{{"role": "user", "content": "Reply with OK."}},
				"max_tokens": 16, "temperature": 0, "stop_sequences": []string{"END"},
				"tools": []any{map[string]any{
					"name": "lookup_weather", "description": "Look up weather.",
					"input_schema": map[string]any{
						"type":       "object",
						"properties": map[string]any{"city": map[string]any{"type": "string"}},
					},
				}},
			},
			required: []string{`"type":"message"`, `"content"`},
		},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			payload, err := json.Marshal(test.body)
			require.NoError(t, err)
			response := postMixedVersionRequest(t, suite, test.endpoint, payload)
			defer response.Body.Close()
			body, err := io.ReadAll(response.Body)
			require.NoError(t, err)
			require.Equal(t, http.StatusOK, response.StatusCode, string(body))
			for _, field := range test.required {
				require.Contains(t, string(body), field)
			}
			assertNoPositiveCachedTokens(t, body)
		})
	}

	t.Run("constrained choices never downgrade to the released provider", func(t *testing.T) {
		for _, choice := range []any{
			"none",
			"required",
			map[string]any{
				"type":     "function",
				"function": map[string]any{"name": "lookup_weather"},
			},
		} {
			payload, err := json.Marshal(map[string]any{
				"model": model,
				"messages": []map[string]string{{
					"role": "user", "content": "Reply with OK.",
				}},
				"max_tokens":  16,
				"tools":       []any{tool},
				"tool_choice": choice,
			})
			require.NoError(t, err)
			response := postMixedVersionRequest(
				t, suite, "/v1/chat/completions", payload)
			body, readErr := io.ReadAll(response.Body)
			response.Body.Close()
			require.NoError(t, readErr)
			require.Equal(t, http.StatusServiceUnavailable, response.StatusCode, string(body))
			require.Contains(t, string(body), "inference-time tool_choice enforcement")
		}
	})

	t.Run("body_limit", func(t *testing.T) {
		oversized := `{"model":` + mustJSON(t, model) +
			`,"messages":[{"role":"user","content":"` +
			strings.Repeat("x", 33<<20) + `"}]}`
		response := postMixedVersionRequest(
			t, suite, "/v1/chat/completions", []byte(oversized))
		defer response.Body.Close()
		body, err := io.ReadAll(response.Body)
		require.NoError(t, err)
		require.Equal(t, http.StatusRequestEntityTooLarge, response.StatusCode, string(body))
	})
}

func postMixedVersionRequest(
	t *testing.T,
	suite *testbed.Suite,
	endpoint string,
	body []byte,
) *http.Response {
	t.Helper()
	request, err := http.NewRequestWithContext(
		suite.Ctx, http.MethodPost, suite.Coordinator.BaseURL()+endpoint, bytes.NewReader(body))
	require.NoError(t, err)
	request.Header.Set("Authorization", "Bearer testbed-admin-key")
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: httpTimeout}).Do(request)
	require.NoError(t, err)
	return response
}

func mustJSON(t *testing.T, value any) string {
	t.Helper()
	encoded, err := json.Marshal(value)
	require.NoError(t, err)
	return string(encoded)
}

func assertNoPositiveCachedTokens(t *testing.T, body []byte) {
	t.Helper()
	var decoded any
	require.NoError(t, json.Unmarshal(body, &decoded))
	var walk func(any)
	walk = func(value any) {
		switch typed := value.(type) {
		case map[string]any:
			for key, child := range typed {
				if key == "cached_tokens" {
					number, ok := child.(float64)
					require.True(t, ok, "cached_tokens must be numeric: %T", child)
					require.Zero(t, number,
						"released protocol must remain cold under the candidate coordinator")
				}
				walk(child)
			}
		case []any:
			for _, child := range typed {
				walk(child)
			}
		}
	}
	walk(decoded)
}
