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

	"github.com/eigeninference/d-inference/e2e/testbed"
)

// mixedVersionSIPRequired is the named reason this lane skips. The pinned
// v0.7.12 artifact is a RELEASE build, and at that tag the SIP check is
// startup-fatal with no escape hatch:
//
//	git show v0.7.12:provider-swift/Sources/ProviderCore/Security/SecurityHardening.swift
//	  :371 public func verifySecurityPosture() throws -> SecurityPosture {
//	  :372     let sipEnabled = checkSIPEnabled()
//	  :373     if !sipEnabled { throw SecurityError.sipDisabled }
//	git show v0.7.12:provider-swift/Sources/ProviderCore/ProviderLoop+Serve.swift
//	  :378 #if !DEBUG
//	  :379 let posture = try verifySecurityPosture()
//
// So on a SIP-disabled host the released provider exits before it ever
// registers, and every downstream wait — suite.Start included — can only
// time out. Saying that plainly is the whole point of this constant.
const mixedVersionSIPRequired = "MIXED_VERSION_SIP_REQUIRED: the hash-pinned released v0.7.12 " +
	"provider is a release build whose verifySecurityPosture() throws SecurityError.sipDisabled " +
	"before serving (SecurityHardening.swift:371-375, called under #if !DEBUG from " +
	"ProviderLoop+Serve.swift:378-379, no env override at that tag), so it cannot register on a " +
	"host whose SIP is not enabled and this gate cannot run here"

// mixedVersionSkipReason maps a measured host SIP state to the reason this
// lane cannot run, or "" when it can. Separated from the measurement so the
// gate's decision is testable for every state without a SIP-disabled host —
// the regression that produced the opaque suite.Start timeout was exactly a
// silent change to this decision.
func mixedVersionSkipReason(state sipState) string {
	if state == sipEnabled {
		return ""
	}
	return mixedVersionSIPRequired
}

// TestIntegrationMixedVersionReleasedV0712Provider is the forward
// compatibility gate: the CANDIDATE coordinator must keep serving the
// hash-pinned RELEASED v0.7.12 provider across every public endpoint.
//
// Why this lane requires SIP instead of tolerating its absence
// ------------------------------------------------------------
// An earlier revision removed the `csrutil status` precondition on the
// premise that "the provider's own SIP check is a warning —
// collectSecurityPosture logs and returns a posture anyway". That premise
// is false for the artifact under test. collectSecurityPosture does not
// exist at v0.7.12 (`git grep collectSecurityPosture v0.7.12` matches
// nothing); it is a CANDIDATE-tree symbol. The released binary runs the
// throwing verifySecurityPosture path quoted on mixedVersionSIPRequired
// above. Dropping the precondition therefore did not make the lane run on
// SIP-disabled hosts — it converted an explicit red into an opaque
// suite.Start timeout.
//
// A gate that physically cannot run must SAY SO, so this skips with a
// named reason. What it asserts WHEN it runs is unchanged and unweakened:
// every precondition past the SIP gate is a require, never a Skip.
//
// Non-vacuity does not rest on the SIP probe. It rests on running against
// the real released artifact, required here by SHA-256 for both the
// executable and its metallib, read from the single source of truth in
// scripts/fetch-v0712-provider.sh. A locally built or drifted bundle fails
// the gate loudly instead of quietly passing it.
func TestIntegrationMixedVersionReleasedV0712Provider(t *testing.T) {
	if os.Getenv("DARKBLOOM_MIXED_VERSION") != "1" {
		t.Skip("set DARKBLOOM_MIXED_VERSION=1 with the verified v0.7.12 binary")
	}
	// Measured once, before anything can block on a provider that will not
	// start. The security_posture subtest reuses this value rather than
	// re-shelling out.
	hostSIP := hostSIPState(t)
	if reason := mixedVersionSkipReason(hostSIP); reason != "" {
		t.Skip(reason)
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
	providerID := providers[0].ID
	providers[0].Mu().Unlock()
	require.Equal(t, "0.7.12", version)
	require.Equal(t, 2, cacheProtocol)
	require.Positive(t, cacheModels)
	require.False(t, cacheStatusReported,
		"released provider unexpectedly advertised candidate cache eligibility telemetry")
	require.Zero(t, donationOutcomes,
		"released provider unexpectedly advertised candidate donation telemetry")

	// The one SIP-dependent claim on this wire surface. It is asserted
	// against the values the provider actually reported, not against the
	// registry copy the testbed has since overwritten.
	t.Run("security_posture", func(t *testing.T) {
		// waitForProviderRegistration force-sets TextBackendInprocess and
		// TextProxyDisabled to true, and materialises the whole block when the
		// provider sent none (testbed/suite.go, the ForEachProvider mutation).
		// NotNil/True asserted on the live registry copy therefore cannot fail
		// for any provider at all. Read the pre-mutation snapshot instead.
		privacy, seen := suite.ReportedPrivacyCapabilities(providerID)
		require.True(t, seen,
			"provider %s was absent when the testbed snapshotted registration state",
			providerID)
		require.NotNil(t, privacy,
			"released provider registered without a privacy_capabilities block")
		// Hardcoded true on the released Swift provider, so these are pure
		// wire round-trip evidence: if they arrive false, the block decoded
		// into zero values.
		require.True(t, privacy.TextBackendInprocess,
			"privacy_capabilities decoded to zero values — wire break, not a posture change")
		require.True(t, privacy.TextProxyDisabled,
			"privacy_capabilities decoded to zero values — wire break, not a posture change")
		switch hostSIP {
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

// releasedMetallibName is the Metal shader library shipped beside the
// released executable inside the bundle, per scripts/fetch-v0712-provider.sh
// (it resolves "$EXTRACTED/Darkbloom.app/Contents/MacOS/mlx.metallib").
const releasedMetallibName = "mlx.metallib"

// requirePinnedReleasedProvider is the anti-vacuous-pass check for this
// gate. It proves the lane is running against the exact released v0.7.12
// artifact the compatibility claim is about.
//
// Both halves of the bundle are pinned, because both determine behaviour
// the gate observes. The executable fixes the wire contract; the metallib
// fixes the kernels that produce the tokens, and it is a separate file that
// can be swapped without touching the binary. The fetch script already
// verifies both (BINARY_SHA256 at :38, METALLIB_SHA256 at :51) — checking
// only one here would let a hand-assembled bundle through a gate whose
// entire value is that it cannot be fooled by a local build.
func requirePinnedReleasedProvider(t *testing.T, path string) {
	t.Helper()
	info, err := os.Stat(path)
	require.NoError(t, err, "released provider binary is unreadable: %s", path)
	require.False(t, info.IsDir(), "released provider binary is a directory: %s", path)
	require.NotZero(t, info.Mode()&0o111,
		"released provider binary is not executable: %s", path)
	require.Equal(t, pinnedReleasedDigest(t, "BINARY_SHA256"), fileDigest(t, path),
		"DARKBLOOM_PROVIDER_BINARY is not the hash-pinned released v0.7.12 artifact; "+
			"fetch it with scripts/fetch-v0712-provider.sh")

	metallib := filepath.Join(filepath.Dir(path), releasedMetallibName)
	metallibInfo, err := os.Stat(metallib)
	require.NoError(t, err,
		"released v0.7.12 metallib is missing beside the binary: %s", metallib)
	require.False(t, metallibInfo.IsDir(),
		"released v0.7.12 metallib is a directory: %s", metallib)
	require.Equal(t, pinnedReleasedDigest(t, "METALLIB_SHA256"), fileDigest(t, metallib),
		"%s is not the hash-pinned released v0.7.12 metallib; the bundle beside "+
			"DARKBLOOM_PROVIDER_BINARY has drifted — re-fetch it with "+
			"scripts/fetch-v0712-provider.sh", metallib)
}

// fileDigest returns the lowercase hex SHA-256 of the file at path.
func fileDigest(t *testing.T, path string) string {
	t.Helper()
	file, err := os.Open(path)
	require.NoError(t, err)
	defer file.Close()
	digest := sha256.New()
	_, err = io.Copy(digest, file)
	require.NoError(t, err)
	return hex.EncodeToString(digest.Sum(nil))
}

// pinnedReleasedDigest reads the named <VAR>_SHA256 assignment out of
// scripts/fetch-v0712-provider.sh rather than restating it, so each pin has
// exactly one definition and the test cannot drift away from the fetcher.
func pinnedReleasedDigest(t *testing.T, variable string) string {
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
		"released-provider fetch script is the single source of truth for the %s pin",
		variable)
	for _, line := range strings.Split(string(contents), "\n") {
		value, found := strings.CutPrefix(strings.TrimSpace(line), variable+"=")
		if !found {
			continue
		}
		value = strings.Trim(value, `"'`)
		require.Len(t, value, 64,
			"%s in %s is not a SHA-256 hex digest", variable, script)
		return value
	}
	require.FailNow(t, "no "+variable+" pin found in "+script)
	return ""
}

// TestIntegrationMixedVersionGateContract pins the two properties whose loss
// produced blocker B3: the lane must announce that it cannot run rather than
// stalling in suite.Start, and it must pin BOTH halves of the released
// bundle. It needs no host, no binary and no SIP state, so it runs wherever
// the compatibility lane itself is filtered in.
func TestIntegrationMixedVersionGateContract(t *testing.T) {
	t.Run("skips_when_sip_is_not_enabled", func(t *testing.T) {
		require.Empty(t, mixedVersionSkipReason(sipEnabled),
			"gate must run on a SIP-enabled host")
		// The released v0.7.12 binary throws SecurityError.sipDisabled before
		// it registers in both of these states, so both must skip loudly.
		require.Equal(t, mixedVersionSIPRequired, mixedVersionSkipReason(sipDisabled))
		require.Equal(t, mixedVersionSIPRequired, mixedVersionSkipReason(sipIndeterminate))
		require.Contains(t, mixedVersionSIPRequired, "MIXED_VERSION_SIP_REQUIRED",
			"skip reason must be greppable in CI output")
	})

	t.Run("both_bundle_pins_are_read_from_the_fetch_script", func(t *testing.T) {
		binary := pinnedReleasedDigest(t, "BINARY_SHA256")
		metallib := pinnedReleasedDigest(t, "METALLIB_SHA256")
		require.NotEqual(t, binary, metallib,
			"metallib pin resolved to the binary pin — the parser matched the wrong line")
		for name, pin := range map[string]string{"BINARY_SHA256": binary, "METALLIB_SHA256": metallib} {
			_, err := hex.DecodeString(pin)
			require.NoError(t, err, "%s is not hex", name)
		}
	})

	t.Run("metallib_drift_fails_the_pin", func(t *testing.T) {
		// requirePinnedReleasedProvider reads the metallib as a sibling of the
		// binary; prove that a bundle whose metallib does not match is rejected
		// rather than accepted because only the executable was checked.
		dir := t.TempDir()
		drifted := filepath.Join(dir, releasedMetallibName)
		require.NoError(t, os.WriteFile(drifted, []byte("not the released metallib"), 0o644))
		require.NotEqual(t, pinnedReleasedDigest(t, "METALLIB_SHA256"), fileDigest(t, drifted))
	})
}
