package e2e

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

// TestIntegrationMixedVersionReleasedV0712Provider is the forward
// compatibility gate: the CANDIDATE coordinator must keep serving the
// hash-pinned RELEASED v0.7.12 provider across every public endpoint.
//
// Why the preamble no longer hard-requires SIP
// --------------------------------------------
// This test used to shell out to `csrutil status` and fail unless SIP was
// enabled ("mandatory v0.7.12 compatibility gate cannot silently skip
// without SIP"). The INTENT — a gate that can never vacuously pass and can
// never be quietly skipped — is correct and is preserved in full below.
// The MECHANISM was wrong: SIP is incidental to everything this test
// exercises, so on a SIP-disabled runner the gate went RED instead of
// running, and v0.7.15's mixed-version compatibility was never verified.
//
// SIP is incidental here because every layer that could depend on it is
// either stubbed by the testbed or log-only in the provider:
//
//   - Coordinator trust is stamped, not measured. testbed/suite.go sets
//     `reg.MinTrustLevel = TrustNone` and forces `TrustSelfSigned` +
//     `ChallengeVerifiedSIP = true` on each registered provider. The one
//     routing gate that reads SIP (providerSupportsPrivateTextLocked)
//     therefore sees a synthetic `true` regardless of the host.
//   - The provider's own SIP check is a warning. collectSecurityPosture
//     logs "SIP is not fully enabled" and returns a posture anyway;
//     applySecurityHardening only throws when the binary self-hash is
//     unavailable, and PT_DENY_ATTACH failure is explicitly non-fatal.
//   - Nothing asserted here is a function of SIP: endpoint shape,
//     PrefixCacheProtocol, the ABSENCE of candidate-only telemetry,
//     cached_tokens, and the 413 body limit are all wire behaviour.
//
// What actually makes the gate non-vacuous is that it runs against the real
// released artifact — so THAT is what is required now, by SHA-256, read
// from the single source of truth in scripts/fetch-v0712-provider.sh. A
// locally built or drifted binary fails the gate loudly instead of quietly
// passing it, which is a strictly stronger guarantee than a csrutil probe
// that never looked at the binary at all.
//
// Every precondition past the DARKBLOOM_MIXED_VERSION opt-in is a require,
// never a Skip. The single genuinely SIP-dependent claim — the value the
// released provider self-reports in privacy_capabilities.sip_enabled — is
// asserted in the security_posture subtest, gated explicitly on the host's
// measured SIP state, and runs (never skips) in both directions.
func TestIntegrationMixedVersionReleasedV0712Provider(t *testing.T) {
	if os.Getenv("DARKBLOOM_MIXED_VERSION") != "1" {
		t.Skip("set DARKBLOOM_MIXED_VERSION=1 with the verified v0.7.12 binary")
	}
	binaryPath := os.Getenv("DARKBLOOM_PROVIDER_BINARY")
	require.NotEmpty(t, binaryPath,
		"mandatory v0.7.12 compatibility gate requires DARKBLOOM_PROVIDER_BINARY "+
			"(scripts/fetch-v0712-provider.sh prints the path)")
	requirePinnedReleasedProvider(t, binaryPath)
	t.Setenv("DARKBLOOM_CBV2_MTP", "0")
	t.Setenv("DARKBLOOM_PREFIX_CACHE", "1")

	const model = "mlx-community/gemma-4-e2b-it-4bit"
	suite := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs: []testbed.ModelSpec{{
			ModelID: model, NumProviders: 1,
		}},
		EnableEphemeralPrefixCache: true,
	})
	require.NoError(t, suite.Start(t.Context()))
	t.Cleanup(suite.Stop)
	warmup, err := json.Marshal(map[string]any{
		"model": model,
		"messages": []map[string]string{{
			"role": "user", "content": "Reply with OK.",
		}},
		"max_tokens": 8, "temperature": 0,
	})
	require.NoError(t, err)
	warmupResponse := postMixedVersionRequest(
		t, suite, "/v1/chat/completions", warmup)
	warmupBody, err := io.ReadAll(warmupResponse.Body)
	warmupResponse.Body.Close()
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, warmupResponse.StatusCode, string(warmupBody))

	require.Eventually(t, func() bool {
		providers := liveProviders(suite.Coordinator.Registry)
		if len(providers) == 0 {
			return false
		}
		providers[0].Mu().Lock()
		defer providers[0].Mu().Unlock()
		return providers[0].Version == "0.7.12" &&
			providers[0].PrefixCacheProtocol == 2 &&
			len(providers[0].PrefixCacheV2Models) > 0
	}, 30*time.Second, 100*time.Millisecond,
		"released v0.7.12 provider never advertised its real v2 cache capability")
	providers := liveProviders(suite.Coordinator.Registry)
	require.NotEmpty(t, providers)
	providers[0].Mu().Lock()
	version := providers[0].Version
	cacheProtocol := providers[0].PrefixCacheProtocol
	cacheModels := len(providers[0].PrefixCacheV2Models)
	cacheStatusReported := providers[0].PrefixCacheStatusReported
	donationOutcomes := len(providers[0].PrefixCacheDonationOutcomes)
	var privacy *protocol.PrivacyCapabilities
	if reported := providers[0].PrivacyCapabilities; reported != nil {
		copied := *reported
		privacy = &copied
	}
	providers[0].Mu().Unlock()
	require.Equal(t, "0.7.12", version)
	require.Equal(t, 2, cacheProtocol)
	require.Positive(t, cacheModels)
	require.False(t, cacheStatusReported,
		"released provider unexpectedly advertised candidate cache eligibility telemetry")
	require.Zero(t, donationOutcomes,
		"released provider unexpectedly advertised candidate donation telemetry")

	// The one SIP-dependent claim on this wire surface, asserted explicitly
	// against the host's measured state instead of being skipped. It runs in
	// both directions and can fail in both: on a SIP-enabled host a provider
	// that stopped reporting posture fails; on a SIP-disabled host a provider
	// that hardcodes an optimistic `true` fails.
	t.Run("security_posture", func(t *testing.T) {
		require.NotNil(t, privacy,
			"released provider's privacy_capabilities block did not survive "+
				"registration under the candidate coordinator")
		// Hardcoded true on the Swift provider in both the hardened and the
		// pre-hardening path, so these are pure wire round-trip evidence: if
		// they arrive false, the block decoded into zero values.
		require.True(t, privacy.TextBackendInprocess,
			"privacy_capabilities decoded to zero values — wire break, not a posture change")
		require.True(t, privacy.TextProxyDisabled,
			"privacy_capabilities decoded to zero values — wire break, not a posture change")
		switch hostSIPState(t) {
		case sipEnabled:
			require.True(t, privacy.SIPEnabled,
				"host SIP is enabled but the released provider reported sip_enabled=false; "+
					"the posture field stopped round-tripping")
		case sipDisabled:
			require.False(t, privacy.SIPEnabled,
				"host SIP is disabled but the released provider reported sip_enabled=true; "+
					"the posture field is no longer host-derived")
			t.Log("host SIP is disabled: sip_enabled=false is asserted, but a zero " +
				"value is indistinguishable from an omitted field on the wire — only a " +
				"SIP-enabled runner proves the positive round-trip")
		case sipIndeterminate:
			t.Log("csrutil reported neither enabled nor disabled; asserting only that " +
				"privacy_capabilities round-tripped, not the value of sip_enabled")
		}
	})

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

// sipState is the host's measured System Integrity Protection state. It is
// tri-valued on purpose: `csrutil status` also reports "unknown (Custom
// Configuration)", and an unavailable csrutil must not be silently folded
// into "disabled" and then asserted against.
type sipState int

const (
	sipIndeterminate sipState = iota
	sipEnabled
	sipDisabled
)

// hostSIPState measures the runner's SIP state without deciding whether the
// test may run. Unlike the preamble it replaced, it never fails the gate:
// the compatibility surface under test does not depend on SIP, so the state
// only selects which posture assertion is the correct one.
func hostSIPState(t *testing.T) sipState {
	t.Helper()
	output, err := exec.Command("/usr/bin/csrutil", "status").CombinedOutput()
	if err != nil {
		t.Logf("csrutil status unavailable (%v): host SIP state is indeterminate", err)
		return sipIndeterminate
	}
	status := string(output)
	t.Logf("host SIP: %s", strings.TrimSpace(status))
	switch {
	case strings.Contains(status, "status: enabled"):
		return sipEnabled
	case strings.Contains(status, "status: disabled"):
		return sipDisabled
	default:
		return sipIndeterminate
	}
}

// requirePinnedReleasedProvider is the anti-vacuous-pass check that replaced
// the SIP probe. It proves the gate is running against the exact released
// v0.7.12 executable the compatibility claim is about — the property the
// csrutil probe was standing in for but never actually established.
func requirePinnedReleasedProvider(t *testing.T, path string) {
	t.Helper()
	info, err := os.Stat(path)
	require.NoError(t, err, "released provider binary is unreadable: %s", path)
	require.False(t, info.IsDir(), "released provider binary is a directory: %s", path)
	require.NotZero(t, info.Mode()&0o111,
		"released provider binary is not executable: %s", path)

	file, err := os.Open(path)
	require.NoError(t, err)
	defer file.Close()
	digest := sha256.New()
	_, err = io.Copy(digest, file)
	require.NoError(t, err)
	require.Equal(t, pinnedReleasedProviderDigest(t), hex.EncodeToString(digest.Sum(nil)),
		"DARKBLOOM_PROVIDER_BINARY is not the hash-pinned released v0.7.12 artifact; "+
			"fetch it with scripts/fetch-v0712-provider.sh")
}

// pinnedReleasedProviderDigest reads BINARY_SHA256 out of
// scripts/fetch-v0712-provider.sh rather than restating it, so the pin has
// exactly one definition and the test cannot drift away from the fetcher.
func pinnedReleasedProviderDigest(t *testing.T) string {
	t.Helper()
	root := os.Getenv("DARKBLOOM_REPO_ROOT")
	if root == "" {
		cwd, err := os.Getwd()
		require.NoError(t, err)
		root = filepath.Clean(filepath.Join(cwd, ".."))
	}
	script := filepath.Join(root, "scripts", "fetch-v0712-provider.sh")
	contents, err := os.ReadFile(script)
	require.NoError(t, err,
		"released-provider fetch script is the single source of truth for the binary pin")
	for _, line := range strings.Split(string(contents), "\n") {
		value, found := strings.CutPrefix(strings.TrimSpace(line), "BINARY_SHA256=")
		if !found {
			continue
		}
		value = strings.Trim(value, `"'`)
		require.Len(t, value, 64,
			"BINARY_SHA256 in %s is not a SHA-256 hex digest", script)
		return value
	}
	require.FailNow(t, "no BINARY_SHA256 pin found in "+script)
	return ""
}
