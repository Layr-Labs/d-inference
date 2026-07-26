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

// mixedVersionSIPRequired is the named reason the PROVIDER-BOOTED half of
// this lane cannot run. The pinned v0.7.12 artifact is a RELEASE build, and
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
	"host whose SIP is not enabled and the provider-booted half of this gate cannot run here"

// Coverage markers this lane prints, one per tier it actually reached.
//
// CI asserts on these rather than on the exit code because `go test` exits 0
// for a skipped test, for a test whose `-run` pattern matched nothing, and
// for a package with no tests at all. The exit code therefore cannot tell
// "verified the pinned bundle" apart from "ran nothing" — which is precisely
// how this lane came to report green while never executing. integration.yml
// greps for the artifact marker and fails the step when it is absent.
const (
	mixedVersionTierArtifactOK = "MIXED_VERSION_TIER_ARTIFACT_OK"
	mixedVersionTierFullOK     = "MIXED_VERSION_TIER_FULL_OK"
)

// mixedVersionExpect is the coverage tier a runner is DESIGNATED to reach,
// read from DARKBLOOM_MIXED_VERSION_EXPECT.
//
// It exists because two different things were previously collapsed into one
// `t.Skip`: whether a host CAN boot the released provider (a fact about the
// host's SIP state) and whether a host is ALLOWED to leave that half unrun
// (a policy about CI). Collapsing them means the designated runner skips
// silently and forever. Blacksmith's macOS runners are SIP-disabled, so the
// honest designation there is `artifact`; point this lane at a SIP-enabled
// runner and set `full`, and a skip is red instead of green.
type mixedVersionExpect string

const (
	// expectAny is a developer laptop: whatever the host can do is fine.
	expectAny mixedVersionExpect = ""
	// expectArtifact designates a runner that MUST verify the pinned bundle.
	// The booted half may skip with a named reason.
	expectArtifact mixedVersionExpect = "artifact"
	// expectFull designates a runner that MUST reach the booted half. A skip
	// there is a CI regression, not a property of the artifact.
	expectFull mixedVersionExpect = "full"
)

// parseMixedVersionExpect rejects unrecognised values instead of folding them
// into expectAny: a typo'd `ful` must not silently downgrade a designated
// runner back to a permanently green skip.
func parseMixedVersionExpect(raw string) (mixedVersionExpect, error) {
	switch expect := mixedVersionExpect(raw); expect {
	case expectAny, expectArtifact, expectFull:
		return expect, nil
	default:
		return expectAny, fmt.Errorf(
			"DARKBLOOM_MIXED_VERSION_EXPECT=%q is not %q, %q or unset", raw, expectArtifact, expectFull)
	}
}

// mixedVersionDecision is the fate of the provider-booted half, decided after
// the artifact half has already run.
type mixedVersionDecision int

const (
	// mixedVersionRun boots the released provider and asserts the whole surface.
	mixedVersionRun mixedVersionDecision = iota
	// mixedVersionSkipBooted: the host cannot boot the released provider and
	// was not designated to. The artifact half has still gated.
	mixedVersionSkipBooted
	// mixedVersionFail: the host cannot boot the released provider but was
	// designated to.
	mixedVersionFail
)

// mixedVersionDecide maps (designated tier, measured SIP) to the fate of the
// booted half and the reason to print. Pure, so the whole matrix is testable
// without a SIP-disabled host. Both regressions this lane has suffered — the
// opaque suite.Start timeout, and the permanent green skip on the only runner
// that executes it — were silent changes to this decision.
func mixedVersionDecide(expect mixedVersionExpect, state sipState) (mixedVersionDecision, string) {
	if state == sipEnabled {
		return mixedVersionRun, ""
	}
	if expect == expectFull {
		return mixedVersionFail, mixedVersionSIPRequired +
			"; DARKBLOOM_MIXED_VERSION_EXPECT=full designated this runner as one that MUST " +
			"reach the released provider, so this is a CI misconfiguration rather than a " +
			"property of the artifact — point the lane at a SIP-enabled runner, or set the " +
			"expectation to artifact and accept that only the bundle pins are gated here"
	}
	return mixedVersionSkipBooted, mixedVersionSIPRequired
}

// TestIntegrationMixedVersionReleasedV0712Provider is the forward
// compatibility gate: the CANDIDATE coordinator must keep serving the
// hash-pinned RELEASED v0.7.12 provider across every public endpoint.
//
// The lane has two tiers, and the split is the whole point
// -------------------------------------------------------
// ARTIFACT tier — verifies that DARKBLOOM_PROVIDER_BINARY is the exact
// released bundle, both the executable and the metallib beside it, by
// SHA-256 read from scripts/fetch-v0712-provider.sh. It needs no provider
// process, no SIP and no GPU, so it runs on EVERY host. This is the check
// that catches a mis-registered release or a hand-assembled bundle, and it
// is unconditional for that reason.
//
// BOOTED tier — everything below, which requires the released provider to
// register. It cannot run on a SIP-disabled host, for the reason named on
// mixedVersionSIPRequired.
//
// Why the booted tier skips rather than hangs, and why that is not enough
// ----------------------------------------------------------------------
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
// Replacing that timeout with a named skip was honest but insufficient: the
// Blacksmith runner in .github/workflows/integration.yml IS SIP-disabled, so
// the named skip meant the only released-provider lane we have never ran and
// always reported green. A gate that cannot fail is not a gate. Hence the
// artifact tier above, which that runner does execute, and
// DARKBLOOM_MIXED_VERSION_EXPECT, which lets CI declare the tier a given
// runner must reach so a skip below the declared tier is red.
//
// What it asserts WHEN it runs is unchanged and unweakened: every
// precondition past the SIP decision is a require, never a Skip.
func TestIntegrationMixedVersionReleasedV0712Provider(t *testing.T) {
	if os.Getenv("DARKBLOOM_MIXED_VERSION") != "1" {
		t.Skip("set DARKBLOOM_MIXED_VERSION=1 with the verified v0.7.12 binary")
	}
	expect, err := parseMixedVersionExpect(os.Getenv("DARKBLOOM_MIXED_VERSION_EXPECT"))
	require.NoError(t, err)

	// ---- ARTIFACT tier: runs on every host, SIP or not. ----
	//
	// Deliberately ahead of the SIP decision. Opting in with
	// DARKBLOOM_MIXED_VERSION=1 and no bundle, or with the wrong bundle, is
	// now red on a SIP-disabled host too, where it used to be a silent skip.
	binaryPath := os.Getenv("DARKBLOOM_PROVIDER_BINARY")
	require.NotEmpty(t, binaryPath,
		"mandatory v0.7.12 compatibility gate requires DARKBLOOM_PROVIDER_BINARY "+
			"(scripts/fetch-v0712-provider.sh prints the path)")
	if !t.Run("pinned_released_artifact", func(t *testing.T) {
		requirePinnedReleasedProvider(t, binaryPath)
	}) {
		t.Fatal("released bundle failed its pins; not proceeding to the booted half")
	}
	t.Log(mixedVersionTierArtifactOK + ": the executable and metallib at " +
		"DARKBLOOM_PROVIDER_BINARY match the digests pinned in " +
		"scripts/fetch-v0712-provider.sh")

	// ---- BOOTED tier: needs the released provider to register. ----
	//
	// Measured once, before anything can block on a provider that will not
	// start. The security_posture subtest reuses this value rather than
	// re-shelling out.
	hostSIP := hostSIPState(t)
	switch decision, reason := mixedVersionDecide(expect, hostSIP); decision {
	case mixedVersionFail:
		t.Fatal(reason)
	case mixedVersionSkipBooted:
		t.Skip(reason)
	case mixedVersionRun:
	}
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

	// Emitted only from the tail of a clean run, so its presence in the job
	// log means the released provider actually booted and every endpoint
	// above was exercised. common.Fail propagates to the parent, so a failed
	// subtest suppresses it.
	if !t.Failed() {
		t.Log(mixedVersionTierFullOK + ": booted the hash-pinned released v0.7.12 " +
			"provider and exercised the whole compatibility surface")
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

// hostSIPState measures the runner's SIP state. It only measures: what the
// state means for the lane is mixedVersionDecide's job, and which posture
// assertion is correct is the security_posture subtest's. Keeping the probe
// free of policy is what makes the whole decision matrix testable on a host
// of any SIP state.
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
	require.NoError(t, verifyPinnedBundle(path,
		pinnedReleasedDigest(t, "BINARY_SHA256"),
		pinnedReleasedDigest(t, "METALLIB_SHA256")),
		"the bundle at DARKBLOOM_PROVIDER_BINARY is not the hash-pinned released "+
			"v0.7.12 artifact; re-fetch it with scripts/fetch-v0712-provider.sh")
}

// verifyPinnedBundle checks both halves of the bundle against their pinned
// digests and returns the first mismatch. It is split out from
// requirePinnedReleasedProvider so every rejection path — including a
// drifted or missing metallib beside a correct executable — is testable
// without a copy of the real released artifact.
func verifyPinnedBundle(binaryPath, wantBinary, wantMetallib string) error {
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
	if got != wantBinary {
		return fmt.Errorf("released provider binary digest %s does not match pinned %s (%s)",
			got, wantBinary, binaryPath)
	}

	metallib := filepath.Join(filepath.Dir(binaryPath), releasedMetallibName)
	metallibInfo, err := os.Stat(metallib)
	if err != nil {
		return fmt.Errorf("released v0.7.12 metallib is missing beside the binary: %w", err)
	}
	if metallibInfo.IsDir() {
		return fmt.Errorf("released v0.7.12 metallib is a directory: %s", metallib)
	}
	got, err = digestFile(metallib)
	if err != nil {
		return err
	}
	if got != wantMetallib {
		return fmt.Errorf("released v0.7.12 metallib digest %s does not match pinned %s (%s)",
			got, wantMetallib, metallib)
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

// TestIntegrationMixedVersionGateContract pins the properties whose loss
// produced blocker B3 and its follow-on: the lane must announce that its
// booted half cannot run rather than stalling in suite.Start, a runner
// DESIGNATED to reach that half must go red instead of skipping, and both
// halves of the released bundle must stay pinned. It needs no host, no
// binary and no SIP state, so it runs wherever the compatibility lane itself
// is filtered in.
func TestIntegrationMixedVersionGateContract(t *testing.T) {
	t.Run("booted_half_decision_matrix", func(t *testing.T) {
		// A SIP-enabled host runs the booted half whatever CI declares.
		for _, expect := range []mixedVersionExpect{expectAny, expectArtifact, expectFull} {
			decision, reason := mixedVersionDecide(expect, sipEnabled)
			require.Equal(t, mixedVersionRun, decision, "expect=%q", expect)
			require.Empty(t, reason)
		}
		// The released v0.7.12 binary throws SecurityError.sipDisabled before
		// it registers in both non-enabled states, so neither can boot it.
		for _, state := range []sipState{sipDisabled, sipIndeterminate} {
			for _, expect := range []mixedVersionExpect{expectAny, expectArtifact} {
				decision, reason := mixedVersionDecide(expect, state)
				require.Equal(t, mixedVersionSkipBooted, decision,
					"state=%d expect=%q", state, expect)
				require.Equal(t, mixedVersionSIPRequired, reason)
			}
			// This is the case the reviewer caught: on the runner designated
			// to execute this lane, a skip must be red. Without it the only
			// released-provider gate we have reports green while never
			// starting the released provider.
			decision, reason := mixedVersionDecide(expectFull, state)
			require.Equal(t, mixedVersionFail, decision,
				"a runner designated full must fail, not skip (state=%d)", state)
			require.Contains(t, reason, "MIXED_VERSION_SIP_REQUIRED")
			require.Contains(t, reason, "DARKBLOOM_MIXED_VERSION_EXPECT=full",
				"failure must name the designation that turned the skip red")
		}
		require.Contains(t, mixedVersionSIPRequired, "MIXED_VERSION_SIP_REQUIRED",
			"skip reason must be greppable in CI output")
	})

	t.Run("expectation_parses_or_rejects", func(t *testing.T) {
		for raw, want := range map[string]mixedVersionExpect{
			"": expectAny, "artifact": expectArtifact, "full": expectFull,
		} {
			got, err := parseMixedVersionExpect(raw)
			require.NoError(t, err, "%q", raw)
			require.Equal(t, want, got)
		}
		// A typo must be red, never a silent downgrade to expectAny — that
		// would hand back the permanent green skip this designation exists
		// to prevent.
		for _, raw := range []string{"ful", "FULL", "artifacts", "1", "true"} {
			_, err := parseMixedVersionExpect(raw)
			require.Error(t, err, "%q must be rejected, not folded into unset", raw)
		}
	})

	t.Run("tier_markers_are_distinct_and_greppable", func(t *testing.T) {
		// integration.yml greps these out of the job log; `go test` exits 0
		// for a skip and for a `-run` pattern that matched nothing, so the
		// markers are the only evidence a tier actually executed.
		require.NotEqual(t, mixedVersionTierArtifactOK, mixedVersionTierFullOK)
		require.NotContains(t, mixedVersionTierFullOK, mixedVersionTierArtifactOK,
			"a grep for the artifact marker must not be satisfied by the full marker alone "+
				"or vice versa")
		require.NotContains(t, mixedVersionTierArtifactOK, mixedVersionTierFullOK)
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

	// The executable is correct in every case below; only the metallib
	// varies. Before this gate verified METALLIB_SHA256 all three passed.
	t.Run("metallib_is_enforced_beside_a_correct_binary", func(t *testing.T) {
		wantMetallib := pinnedReleasedDigest(t, "METALLIB_SHA256")
		newBundle := func(t *testing.T, metallib []byte) (dir, binary, binaryDigest string) {
			t.Helper()
			dir = t.TempDir()
			binary = filepath.Join(dir, "darkbloom")
			require.NoError(t, os.WriteFile(binary, []byte("released executable"), 0o755))
			digest, err := digestFile(binary)
			require.NoError(t, err)
			if metallib != nil {
				require.NoError(t,
					os.WriteFile(filepath.Join(dir, releasedMetallibName), metallib, 0o644))
			}
			return dir, binary, digest
		}

		_, binary, binaryDigest := newBundle(t, []byte("drifted metallib"))
		require.ErrorContains(t, verifyPinnedBundle(binary, binaryDigest, wantMetallib),
			"metallib digest",
			"a drifted metallib beside a correct binary was accepted")

		_, binary, binaryDigest = newBundle(t, nil)
		require.ErrorContains(t, verifyPinnedBundle(binary, binaryDigest, wantMetallib),
			"metallib is missing",
			"a bundle with no metallib at all was accepted")

		// Matching metallib beside a matching binary is the only accepted case.
		matching := []byte("released metallib bytes")
		matchingDigest := sha256.Sum256(matching)
		_, binary, binaryDigest = newBundle(t, matching)
		require.NoError(t, verifyPinnedBundle(
			binary, binaryDigest, hex.EncodeToString(matchingDigest[:])))
	})
}
