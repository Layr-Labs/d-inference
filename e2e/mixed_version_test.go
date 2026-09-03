package e2e

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
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

// mixedVersionSIPRequired is the named reason the FULL selector cannot run on
// this host. The pinned v0.7.12 artifact is a RELEASE build, and
// at that tag the SIP check is startup-fatal with no escape hatch:
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
	"host whose SIP is not enabled and the full compatibility gate cannot run here"

// Coverage markers this lane prints, one per test it actually completed.
//
// CI asserts on these rather than on the exit code because `go test` exits 0
// for a skipped test, for a test whose `-run` pattern matched nothing, and
// for a package with no tests at all. The names intentionally say whether the
// released provider booted: SIP-disabled CI only proves the artifact contract.
const (
	mixedVersionArtifactOnlyOK = "MIXED_VERSION_TIER_ARTIFACT_ONLY_NO_LEGACY_BOOT_OK"
	mixedVersionFullBootOK     = "MIXED_VERSION_TIER_FULL_LEGACY_BOOT_OK"
)

// releasedProviderV0712 is an independent, structured compatibility fixture.
// Do not derive these values by scraping the fetch shell script: changing the
// fetcher and the downloaded artifact together must not silently rewrite the
// test's expectation of which released bundle it is certifying.
var releasedProviderV0712 = releasedProviderArtifact{
	version:        "0.7.12",
	binarySHA256:   "c74b4829454bc4e2e40a0d9791458d17ba3dd278a5238ec628145b172016584d",
	metallibName:   "mlx.metallib",
	metallibSHA256: "e2d5853b79925b3661861fed79f30b1aeb636a52ebbde15b054711ce865edfaa",
}

type releasedProviderArtifact struct {
	version        string
	binarySHA256   string
	metallibName   string
	metallibSHA256 string
}

// mixedVersionExpect is the explicit tier owned by this invocation, read from
// DARKBLOOM_MIXED_VERSION_EXPECT. There is no implicit developer tier: an
// unset or misspelled value must not make either exact selector ambiguous.
type mixedVersionExpect string

const (
	// expectArtifact designates the SIP-independent, no-provider-boot gate.
	expectArtifact mixedVersionExpect = "artifact"
	// expectFull designates a SIP-enabled runner that boots the legacy provider.
	expectFull mixedVersionExpect = "full"
)

func parseMixedVersionExpect(raw string) (mixedVersionExpect, error) {
	switch expect := mixedVersionExpect(raw); expect {
	case expectArtifact, expectFull:
		return expect, nil
	default:
		return "", fmt.Errorf(
			"DARKBLOOM_MIXED_VERSION_EXPECT=%q is not %q or %q",
			raw, expectArtifact, expectFull)
	}
}

func requireMixedVersionTier(t *testing.T, required mixedVersionExpect) {
	t.Helper()
	if os.Getenv("DARKBLOOM_MIXED_VERSION") != "1" {
		t.Skip("set DARKBLOOM_MIXED_VERSION=1 with the verified v0.7.12 bundle")
	}
	expect, err := parseMixedVersionExpect(os.Getenv("DARKBLOOM_MIXED_VERSION_EXPECT"))
	require.NoError(t, err)
	require.Equal(t, required, expect,
		"this exact selector owns only the %q tier; set "+
			"DARKBLOOM_MIXED_VERSION_EXPECT=%s", required, required)
}

func mixedVersionProviderBinary(t *testing.T) string {
	t.Helper()
	path := os.Getenv("DARKBLOOM_PROVIDER_BINARY")
	require.NotEmpty(t, path,
		"v0.7.12 compatibility gates require DARKBLOOM_PROVIDER_BINARY "+
			"(scripts/fetch-v0712-provider.sh prints the verified path)")
	return path
}

// TestIntegrationMixedVersionArtifactOnlyV0712 is the SIP-independent gate.
// It verifies the released executable and metallib and deliberately does not
// start a provider, coordinator, database, or model. Its name and completion
// marker make that limitation explicit in SIP-disabled CI.
func TestIntegrationMixedVersionArtifactOnlyV0712(t *testing.T) {
	requireMixedVersionTier(t, expectArtifact)
	requirePinnedReleasedProvider(t, mixedVersionProviderBinary(t))
	t.Log(mixedVersionArtifactOnlyOK +
		": verified the independent v0.7.12 executable and metallib pins; " +
		"the legacy provider was NOT booted")
}

// TestIntegrationMixedVersionFullV0712Provider is the forward compatibility
// gate: the candidate coordinator must serve the hash-pinned released v0.7.12
// provider across the public inference endpoints. This selector is owned only
// by a SIP-enabled runner; selecting it anywhere else is a failure, never a
// skip. It independently verifies the bundle before starting the provider, so
// the full compatibility claim cannot be made against a local build.
func TestIntegrationMixedVersionFullV0712Provider(t *testing.T) {
	requireMixedVersionTier(t, expectFull)
	requirePinnedReleasedProvider(t, mixedVersionProviderBinary(t))

	// Measured before suite.Start, which would otherwise wait for a release
	// binary that exits on its startup-fatal SIP check.
	hostSIP := hostSIPState(t)
	require.Equal(t, sipEnabled, hostSIP, mixedVersionSIPRequired+
		"; the full selector requires explicit ownership by a SIP-enabled runner")

	t.Setenv("DARKBLOOM_CBV2_MTP", "0")
	t.Setenv("DARKBLOOM_PREFIX_CACHE", "1")

	const model = "mlx-community/gemma-4-e2b-it-4bit"
	suite := testbed.StartSuite(t, testbed.SuiteConfig{
		ModelSpecs: []testbed.ModelSpec{{
			ModelID: model, NumProviders: 1,
		}},
		EnableEphemeralPrefixCache: true,
	})
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

	// Assert against the provider's original registration values, not the
	// registry copy the testbed subsequently normalizes.
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
		require.True(t, privacy.SIPEnabled,
			"the SIP-enabled full runner received sip_enabled=false from the released "+
				"provider; the posture field stopped round-tripping")
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

	// Emitted only from the tail of a clean run, so its presence in the job
	// log means the released provider actually booted and every endpoint
	// above was exercised. common.Fail propagates to the parent, so a failed
	// subtest suppresses it.
	if !t.Failed() {
		t.Log(mixedVersionFullBootOK + ": booted the hash-pinned released v0.7.12 " +
			"provider and exercised endpoints, response bodies, privacy, and cache behavior")
	}
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

// hostSIPState measures without policy. The full selector requires sipEnabled
// before suite.Start and reuses the same value for the provider-reported
// security posture assertion.
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

// requirePinnedReleasedProvider is the anti-vacuous check shared by both
// exact selectors. Both halves determine observed behavior: the executable
// fixes the wire contract and the separately swappable metallib fixes the
// kernels producing tokens.
func requirePinnedReleasedProvider(t *testing.T, path string) {
	t.Helper()
	require.NoError(t, verifyPinnedBundle(path, releasedProviderV0712),
		"the bundle at DARKBLOOM_PROVIDER_BINARY is not the independently "+
			"hash-pinned released v0.7.12 artifact; re-fetch it with "+
			"scripts/fetch-v0712-provider.sh")
}

// verifyPinnedBundle checks both halves of a structured release fixture and
// returns the first mismatch. Keeping the fixture independent from the fetch
// shell means a fetch-script edit cannot silently change this gate's identity.
func verifyPinnedBundle(binaryPath string, artifact releasedProviderArtifact) error {
	info, err := os.Stat(binaryPath)
	if err != nil {
		return fmt.Errorf("released provider binary is unreadable: %w", err)
	}
	if info.IsDir() {
		return fmt.Errorf("released provider binary is a directory: %s", binaryPath)
	}
	if info.Mode()&0o111 == 0 {
		return fmt.Errorf("released provider binary is not executable: %s", binaryPath)
	}
	got, err := digestFile(binaryPath)
	if err != nil {
		return err
	}
	if got != artifact.binarySHA256 {
		return fmt.Errorf("released provider binary digest %s does not match pinned %s (%s)",
			got, artifact.binarySHA256, binaryPath)
	}

	metallib := filepath.Join(filepath.Dir(binaryPath), artifact.metallibName)
	metallibInfo, err := os.Stat(metallib)
	if err != nil {
		return fmt.Errorf("released v%s metallib is missing beside the binary: %w",
			artifact.version, err)
	}
	if metallibInfo.IsDir() {
		return fmt.Errorf("released v%s metallib is a directory: %s",
			artifact.version, metallib)
	}
	got, err = digestFile(metallib)
	if err != nil {
		return err
	}
	if got != artifact.metallibSHA256 {
		return fmt.Errorf("released v%s metallib digest %s does not match pinned %s (%s)",
			artifact.version, got, artifact.metallibSHA256, metallib)
	}
	return nil
}

// digestFile returns the lowercase hex SHA-256 of the file at path.
func digestFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

// TestIntegrationMixedVersionGateContract is the pure contract for tier
// ownership, anti-vacuous completion markers, and structured artifact pins.
// It starts no process and reads no shell source.
func TestIntegrationMixedVersionGateContract(t *testing.T) {
	t.Run("expectation_parses_or_rejects", func(t *testing.T) {
		for raw, want := range map[string]mixedVersionExpect{
			"artifact": expectArtifact, "full": expectFull,
		} {
			got, err := parseMixedVersionExpect(raw)
			require.NoError(t, err, "%q", raw)
			require.Equal(t, want, got)
		}
		for _, raw := range []string{"", "ful", "FULL", "artifacts", "1", "true"} {
			_, err := parseMixedVersionExpect(raw)
			require.Error(t, err, "%q must be rejected, not silently assigned a tier", raw)
		}
	})

	t.Run("tier_markers_name_distinct_completion_contracts", func(t *testing.T) {
		// CI greps exact markers because a zero-match or all-skipped `go test`
		// exits successfully. Neither marker may be a substring of the other.
		require.Contains(t, mixedVersionArtifactOnlyOK, "ARTIFACT_ONLY")
		require.Contains(t, mixedVersionArtifactOnlyOK, "NO_LEGACY_BOOT")
		require.Contains(t, mixedVersionFullBootOK, "FULL_LEGACY_BOOT")
		require.NotEqual(t, mixedVersionArtifactOnlyOK, mixedVersionFullBootOK)
		require.NotContains(t, mixedVersionFullBootOK, mixedVersionArtifactOnlyOK)
		require.NotContains(t, mixedVersionArtifactOnlyOK, mixedVersionFullBootOK)
		require.Contains(t, mixedVersionSIPRequired, "MIXED_VERSION_SIP_REQUIRED")
	})

	t.Run("released_fixture_pins_both_bundle_members", func(t *testing.T) {
		require.Equal(t, "0.7.12", releasedProviderV0712.version)
		require.Equal(t, "mlx.metallib", releasedProviderV0712.metallibName)
		require.NotEqual(t, releasedProviderV0712.binarySHA256,
			releasedProviderV0712.metallibSHA256)
		for name, pin := range map[string]string{
			"binary":   releasedProviderV0712.binarySHA256,
			"metallib": releasedProviderV0712.metallibSHA256,
		} {
			require.Len(t, pin, sha256.Size*2, "%s pin is not SHA-256", name)
			decoded, err := hex.DecodeString(pin)
			require.NoError(t, err, "%s pin is not hex", name)
			require.Len(t, decoded, sha256.Size)
		}
	})

	t.Run("verifier_rejects_drift_and_requires_both_members", func(t *testing.T) {
		newBundle := func(t *testing.T, metallib []byte) (string, releasedProviderArtifact) {
			t.Helper()
			dir := t.TempDir()
			binary := filepath.Join(dir, "darkbloom")
			binaryBytes := []byte("released executable")
			require.NoError(t, os.WriteFile(binary, binaryBytes, 0o755))
			fixture := releasedProviderArtifact{
				version:        releasedProviderV0712.version,
				binarySHA256:   hex.EncodeToString(sha256Sum(binaryBytes)),
				metallibName:   releasedProviderV0712.metallibName,
				metallibSHA256: hex.EncodeToString(sha256Sum(metallib)),
			}
			if metallib != nil {
				require.NoError(t,
					os.WriteFile(filepath.Join(dir, fixture.metallibName), metallib, 0o644))
			}
			return binary, fixture
		}

		matching := []byte("released metallib bytes")
		binary, fixture := newBundle(t, matching)
		require.NoError(t, verifyPinnedBundle(binary, fixture))

		driftedBinary := fixture
		driftedBinary.binarySHA256 = strings.Repeat("0", sha256.Size*2)
		require.ErrorContains(t, verifyPinnedBundle(binary, driftedBinary),
			"binary digest")

		driftedMetallib := fixture
		driftedMetallib.metallibSHA256 = strings.Repeat("0", sha256.Size*2)
		require.ErrorContains(t, verifyPinnedBundle(binary, driftedMetallib),
			"metallib digest")

		binary, fixture = newBundle(t, nil)
		require.ErrorContains(t, verifyPinnedBundle(binary, fixture),
			"metallib is missing")
	})
}

func sha256Sum(contents []byte) []byte {
	sum := sha256.Sum256(contents)
	return sum[:]
}
