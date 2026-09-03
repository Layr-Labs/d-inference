package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
	tbassert "github.com/eigeninference/d-inference/e2e/testbed/assert"
)

var (
	benchmarkMarkdownMu sync.Mutex
	benchmarkMarkdown   strings.Builder
	benchmarkControlMu  sync.Mutex
	benchmarkControls   = make(map[benchmarkControlKey]struct{})
)

const benchmarkMinimumSuccessPercent = 90

const benchmarkControlFirstContentDeadlineBase = 30 * time.Second

type benchmarkControlKey struct {
	modelID         string
	kvBackend       string
	expectKVBackend string
	maxConcurrent   int
}

func init() {
	benchmarkMarkdown.WriteString("# Benchmark Results\n\n")
	benchmarkMarkdown.WriteString(fmt.Sprintf("Runner: `%s` | Date: %s\n\n",
		envOr("RUNNER_DESC", "local"),
		time.Now().UTC().Format("2006-01-02 15:04 UTC")))
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func benchmarkSuiteConfig(cfg testbed.SuiteConfig) testbed.SuiteConfig {
	if cfg.ExpectKVBackend != "" || os.Getenv(testbed.EnvExpectKVBackend) != "" {
		// Preserve the verifier's environment fallback verbatim, including its
		// fail-closed validation of malformed expectations.
		return cfg
	}

	// Benchmarks measure steady serving throughput, not cold model-load time.
	// Declaring the expected backend makes Suite.Start pre-warm every
	// (provider, model) slot through the production load_model push and wait for
	// the first capacity heartbeat before the measured load begins.
	requested := testbed.ResolveKVBackend(cfg.KVBackend)
	switch requested {
	case "", testbed.KVBackendAuto, testbed.KVBackendContiguous:
		cfg.ExpectKVBackend = testbed.KVBackendContiguous
	default:
		// Explicit paged resolves to paged or refuses; malformed values are
		// rejected by ResolveExpectedKVBackend during suite startup.
		cfg.ExpectKVBackend = requested
	}
	return cfg
}

func benchmarkControlSuiteConfig(measured testbed.SuiteConfig, modelID string) testbed.SuiteConfig {
	return benchmarkSuiteConfig(testbed.SuiteConfig{
		ModelSpecs:                 []testbed.ModelSpec{{ModelID: modelID, NumProviders: 1}},
		NumUsers:                   1,
		QueueCapacity:              10,
		QueueTimeout:               measured.QueueTimeout,
		FirstContentDeadlineBase:   benchmarkControlFirstContentDeadlineBase,
		SeedBalance:                measured.SeedBalance,
		UseMemoryStore:             measured.UseMemoryStore,
		EnableEphemeralPrefixCache: measured.EnableEphemeralPrefixCache,
		KVBackend:                  measured.KVBackend,
		MaxConcurrent:              measured.MaxConcurrent,
		ExpectKVBackend:            measured.ExpectKVBackend,
	})
}

func benchmarkControlCacheKey(cfg testbed.SuiteConfig, modelID string) benchmarkControlKey {
	expected := cfg.ExpectKVBackend
	if expected == "" {
		expected = os.Getenv(testbed.EnvExpectKVBackend)
	}
	return benchmarkControlKey{
		modelID:         modelID,
		kvBackend:       testbed.ResolveKVBackend(cfg.KVBackend),
		expectKVBackend: expected,
		maxConcurrent:   cfg.MaxConcurrent,
	}
}

func TestBenchmarkSuiteConfigPrewarmsResolvedBackend(t *testing.T) {
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", "")

	for _, tc := range []struct {
		name     string
		cfg      testbed.SuiteConfig
		expected string
	}{
		{name: "provider default", cfg: testbed.SuiteConfig{}, expected: testbed.KVBackendContiguous},
		{name: "auto", cfg: testbed.SuiteConfig{KVBackend: testbed.KVBackendAuto}, expected: testbed.KVBackendContiguous},
		{name: "contiguous", cfg: testbed.SuiteConfig{KVBackend: testbed.KVBackendContiguous}, expected: testbed.KVBackendContiguous},
		{name: "paged", cfg: testbed.SuiteConfig{KVBackend: testbed.KVBackendPaged}, expected: testbed.KVBackendPaged},
		{name: "caller expectation wins", cfg: testbed.SuiteConfig{ExpectKVBackend: testbed.KVBackendPaged}, expected: testbed.KVBackendPaged},
	} {
		t.Run(tc.name, func(t *testing.T) {
			require.Equal(t, tc.expected, benchmarkSuiteConfig(tc.cfg).ExpectKVBackend)
		})
	}

	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", testbed.KVBackendPaged)
	require.Equal(t, testbed.KVBackendPaged,
		benchmarkSuiteConfig(testbed.SuiteConfig{}).ExpectKVBackend)
}

func TestBenchmarkSuiteConfigPreservesExpectedBackendEnvironment(t *testing.T) {
	for _, value := range []string{testbed.KVBackendPaged, "pagd"} {
		t.Setenv(testbed.EnvExpectKVBackend, value)
		cfg := benchmarkSuiteConfig(testbed.SuiteConfig{})
		require.Empty(t, cfg.ExpectKVBackend)
	}
}

func TestBenchmarkControlSuiteIsIsolatedAndMatchesPosture(t *testing.T) {
	measured := testbed.SuiteConfig{
		ModelSpecs:      []testbed.ModelSpec{{ModelID: "m/one", NumProviders: 7}},
		QueueTimeout:    42 * time.Second,
		SeedBalance:     123,
		KVBackend:       testbed.KVBackendPaged,
		MaxConcurrent:   8,
		ExpectKVBackend: testbed.KVBackendPaged,
	}
	control := benchmarkControlSuiteConfig(measured, "m/two")

	require.Equal(t, 1, control.TotalProviders())
	require.Equal(t, []string{"m/two"}, control.AllModelIDs())
	require.Equal(t, benchmarkControlFirstContentDeadlineBase, control.FirstContentDeadlineBase)
	require.Equal(t, measured.QueueTimeout, control.QueueTimeout)
	require.Equal(t, measured.SeedBalance, control.SeedBalance)
	require.Equal(t, measured.KVBackend, control.KVBackend)
	require.Equal(t, measured.MaxConcurrent, control.MaxConcurrent)
	require.Equal(t, measured.ExpectKVBackend, control.ExpectKVBackend)
}

func canonicalCapacityRejection(rr testbed.RequestResult) bool {
	if rr.StatusCode != http.StatusTooManyRequests || rr.Error == nil {
		return false
	}
	const errorPrefix = "status 429: "
	raw := rr.Error.Error()
	if !strings.HasPrefix(raw, errorPrefix) {
		return false
	}

	var envelope struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal([]byte(strings.TrimPrefix(raw, errorPrefix)), &envelope) != nil ||
		envelope.Error.Code != "rate_limit_exceeded" {
		return false
	}

	message := envelope.Error.Message
	return strings.HasPrefix(message, "all providers at capacity after ") ||
		(strings.HasPrefix(message, "all providers for model ") &&
			strings.Contains(message, " are at capacity"))
}

func canonicalFullCapacityRejection(result *testbed.LoadResult) bool {
	if result == nil || result.SuccessCount != 0 || len(result.RequestResults) == 0 {
		return false
	}
	for _, rr := range result.RequestResults {
		if !canonicalCapacityRejection(rr) {
			return false
		}
	}
	return true
}

func benchmarkErrorResult(status int, code, message string) testbed.RequestResult {
	body, _ := json.Marshal(map[string]any{
		"error": map[string]string{"code": code, "message": message},
	})
	return testbed.RequestResult{
		StatusCode: status,
		Error:      fmt.Errorf("status %d: %s", status, body),
	}
}

func TestBenchmarkCapacitySaturationPolicy(t *testing.T) {
	capacity := benchmarkErrorResult(
		http.StatusTooManyRequests,
		"rate_limit_exceeded",
		"all providers at capacity after 2 attempt(s): timeout waiting for first response")
	queueFull := benchmarkErrorResult(
		http.StatusTooManyRequests,
		"rate_limit_exceeded",
		`all providers for model "m" are at capacity and queue is full`)
	require.True(t, canonicalFullCapacityRejection(&testbed.LoadResult{
		RequestResults: []testbed.RequestResult{capacity, queueFull},
	}))

	for _, rejected := range []testbed.RequestResult{
		{StatusCode: http.StatusTooManyRequests},
		benchmarkErrorResult(http.StatusTooManyRequests, "rate_limit_exceeded",
			`model "m" is temporarily rate-limited — retry after 10s`),
		benchmarkErrorResult(http.StatusTooManyRequests, "rate_limit_exceeded",
			`all providers for model "m" are above the 9s TTFT target`),
		benchmarkErrorResult(http.StatusTooManyRequests, "rate_limit_exceeded",
			`no provider could produce first content within the remaining deadline for model "m"`),
		benchmarkErrorResult(http.StatusInternalServerError, "provider_error", "inference failed"),
	} {
		require.False(t, canonicalFullCapacityRejection(&testbed.LoadResult{
			RequestResults: []testbed.RequestResult{rejected},
		}))
	}

	require.False(t, canonicalFullCapacityRejection(&testbed.LoadResult{}))
	require.False(t, canonicalFullCapacityRejection(&testbed.LoadResult{
		SuccessCount:   1,
		RequestResults: []testbed.RequestResult{{StatusCode: http.StatusOK}},
	}))
}

func requireBenchmarkControls(
	t *testing.T,
	ctx context.Context,
	measuredCfg testbed.SuiteConfig,
) {
	t.Helper()
	for _, modelID := range measuredCfg.AllModelIDs() {
		controlCfg := benchmarkControlSuiteConfig(measuredCfg, modelID)
		key := benchmarkControlCacheKey(controlCfg, modelID)

		func() {
			benchmarkControlMu.Lock()
			defer benchmarkControlMu.Unlock()
			if _, ok := benchmarkControls[key]; ok {
				return
			}

			t.Logf("proving model %s with an isolated one-provider control before measured topology startup",
				modelID)
			controlSuite := testbed.NewSuite(controlCfg)
			require.NoError(t, controlSuite.Start(ctx), "benchmark control suite startup failed")
			defer controlSuite.Stop()

			control := testbed.DefaultRequestConfig()
			control.ModelID = modelID
			control.Streaming = false
			control.TotalRequests = 1
			control.Concurrency = 1
			control.MaxTokens = 1
			control.ExpectedSuccesses = 1
			control.MinimumSuccesses = 1

			result, err := testbed.NewLoadGenerator(controlSuite, control).Run()
			require.NotNil(t, result, "control load generator must return its measurements")
			require.NoError(t, err,
				"isolated prewarmed model %s must serve before saturation is measurable",
				modelID)
			require.Equal(t, 1, result.SuccessCount,
				"isolated prewarmed model %s must serve before saturation is measurable",
				modelID)
			require.Len(t, result.RequestResults, 1)
			require.Equal(t, http.StatusOK, result.RequestResults[0].StatusCode)
			benchmarkControls[key] = struct{}{}
		}()
	}
}

// runBenchmark records full capacity saturation as a valid benchmark outcome
// only after every model serves through an isolated one-provider control. The
// measured topology still uses the production first-content deadline; the
// blocking integration suite owns broader functional and SLO guarantees. A
// zero-success measured cell is valid only when every request received the
// canonical 429 — transport errors and 5xx responses still fail the run —
// and a cell with any successes must still clear the benchmark success floor
// (MinimumSuccesses).
func runBenchmark(t *testing.T, name string, suiteCfg testbed.SuiteConfig, reqCfg testbed.RequestConfig) {
	t.Helper()

	reqCfg.ExpectedSuccesses = reqCfg.TotalRequests
	reqCfg.MinimumSuccesses = minimumBenchmarkSuccesses(reqCfg.TotalRequests)

	suiteCfg = benchmarkSuiteConfig(suiteCfg)
	requireBenchmarkControls(t, context.Background(), suiteCfg)

	s := testbed.StartSuite(t, suiteCfg)

	t.Logf("[%s] %d providers (%v), %d users, models=%v, requests=%d, concurrency=%d, streaming=%v, first_content_deadline_base=%s",
		name, suiteCfg.TotalProviders(), suiteCfg.ModelSpecs, suiteCfg.NumUsers, suiteCfg.AllModelIDs(),
		reqCfg.TotalRequests, reqCfg.Concurrency, reqCfg.Streaming, s.Config.FirstContentDeadlineBase)

	result, loadErr := testbed.NewLoadGenerator(s, reqCfg).Run()
	require.NotNil(t, result, "load generator must return its measurements")
	t.Logf("\n%s", result.SummaryTable())
	for i, failure := range result.Failures {
		require.Errorf(t, failure.Err, "failed request %d must retain its exact error", failure.Index)
		if i < 5 {
			t.Logf("request failure: %s", failure.Error())
		}
	}

	saturated := result.SuccessCount == 0 && canonicalFullCapacityRejection(result)
	if saturated {
		t.Log("all requests were rejected with the canonical 429; recording the capacity boundary")
	} else {
		require.NoError(t, loadErr, "benchmark workload failed its overall success threshold")
	}

	require.Equal(t, reqCfg.TotalRequests, result.TotalRequests,
		"load result must preserve the configured workload size")
	require.Len(t, result.RequestResults, reqCfg.TotalRequests,
		"load generator must account for every request")
	require.Equal(t, result.TotalRequests, result.SuccessCount+result.ErrorCount,
		"success and error counts must account for the full workload")
	require.Len(t, result.Failures, result.ErrorCount,
		"every failed request must retain its exact error")
	require.Equal(t, reqCfg.ExpectedSuccesses, result.ExpectedSuccesses)
	require.Equal(t, reqCfg.MinimumSuccesses, result.MinimumSuccesses)
	if !saturated {
		requireSuccessRatio(t, "overall workload", result.SuccessCount, result.TotalRequests)
	}

	t.Logf("\nPer-model breakdown:")
	for _, modelID := range suiteCfg.AllModelIDs() {
		stats, ok := result.ModelCohorts[modelID]
		require.Truef(t, ok, "configured model %q received no requests", modelID)
		t.Logf("  %-45s total=%d success=%d errors=%d",
			modelID, stats.TotalRequests, stats.SuccessCount, stats.ErrorCount)
		require.Equal(t, stats.TotalRequests, stats.SuccessCount+stats.ErrorCount,
			"model cohort %q has incomplete accounting", modelID)
		require.Len(t, stats.Failures, stats.ErrorCount,
			"model cohort %q must retain every error", modelID)
		if !saturated {
			requireSuccessRatio(t, "model "+modelID, stats.SuccessCount, stats.TotalRequests)
		}
	}

	t.Logf("\nPer-user breakdown:")
	for userIndex := range suiteCfg.NumUsers {
		stats, ok := result.UserCohorts[userIndex]
		require.Truef(t, ok, "configured user-%d received no requests", userIndex)
		t.Logf("  user-%d: total=%d success=%d errors=%d",
			userIndex, stats.TotalRequests, stats.SuccessCount, stats.ErrorCount)
		require.Equal(t, stats.TotalRequests, stats.SuccessCount+stats.ErrorCount,
			"user-%d cohort has incomplete accounting", userIndex)
		require.Len(t, stats.Failures, stats.ErrorCount,
			"user-%d cohort must retain every error", userIndex)
		if !saturated {
			requireSuccessRatio(t, fmt.Sprintf("user-%d", userIndex), stats.SuccessCount, stats.TotalRequests)
		}
	}

	if reqCfg.Streaming {
		require.NotNil(t, result.ProfileRun, "streaming workload must report TTFT metrics")
		require.Len(t, result.ProfileRun.TTFTs, result.SuccessCount,
			"every successful streaming request must report TTFT")
		for i, ttft := range result.ProfileRun.TTFTs {
			require.Positivef(t, ttft, "TTFT sample %d must be positive", i)
		}
		for _, request := range result.RequestResults {
			if request.Error == nil && request.StatusCode == 200 {
				require.Positivef(t, request.TTFT,
					"successful streaming request %d must record TTFT", request.Index)
			}
		}
	}

	var assertReport *tbassert.AssertionReport
	if saturated {
		// An accepted capacity boundary has zero 200s, so aggregate holds no
		// parse/reserve/encrypt/dispatch samples; evaluating the overhead
		// thresholds would fail every segment as missing rather than measure
		// anything. The isolated control request already proved the
		// coordinator serves this posture.
		t.Logf("skipping coordinator overhead thresholds: cell accepted as saturated (no successful-request timing samples)")
	} else {
		assertReport = tbassert.NewAsserter(tbassert.CoordinatorOverheadThresholds()).Evaluate(result.SegmentStatsMap())
		t.Logf("\n%s", assertReport.SummaryTable())
		for _, assertion := range assertReport.Results {
			if !assertion.Passed {
				t.Logf("FAILED: %s — %s", assertion.Name, assertion.Message)
			}
		}
		require.True(t, assertReport.Passed, "coordinator overhead thresholds failed")
	}

	benchmarkMarkdownMu.Lock()
	benchmarkMarkdown.WriteString(fmt.Sprintf("## %s\n\n", name))
	benchmarkMarkdown.WriteString(fmt.Sprintf("%d providers, %d users, %d requests, concurrency=%d, streaming=%v\n\n",
		suiteCfg.TotalProviders(), suiteCfg.NumUsers, reqCfg.TotalRequests, reqCfg.Concurrency, reqCfg.Streaming))
	benchmarkMarkdown.WriteString("| Model | Providers | RAM |\n|---|---|---|\n")
	for _, spec := range suiteCfg.ModelSpecs {
		for _, modelID := range spec.IDs() {
			ram, ok := testbed.KnownModelSizes[modelID]
			if !ok {
				ram = "unknown"
			}
			benchmarkMarkdown.WriteString(fmt.Sprintf("| %s | %d | %s |\n", modelID, spec.NumProviders, ram))
		}
	}
	benchmarkMarkdown.WriteString("\n")
	benchmarkMarkdown.WriteString(result.SummaryMarkdown())
	benchmarkMarkdown.WriteString("\n")
	if assertReport != nil {
		benchmarkMarkdown.WriteString(assertReport.SummaryMarkdown())
	} else {
		benchmarkMarkdown.WriteString("_Coordinator overhead thresholds skipped: cell accepted as a saturated capacity boundary (no successful-request timing samples)._\n")
	}
	benchmarkMarkdown.WriteString("\n\n")
	benchmarkMarkdownMu.Unlock()
}

func TestMain(m *testing.M) {
	code := m.Run()

	if code == 0 {
		benchmarkMarkdownMu.Lock()
		md := benchmarkMarkdown.String()
		benchmarkMarkdownMu.Unlock()

		if outPath := os.Getenv("BENCHMARK_MD_PATH"); outPath != "" && md != "" {
			if err := os.WriteFile(outPath, []byte(md), 0o644); err != nil {
				fmt.Fprintf(os.Stderr, "write benchmark results to %q: %v\n", outPath, err)
				code = 1
			}
		}
	}

	os.Exit(code)
}

func TestBenchmark_SingleProviderStreaming(t *testing.T) {
	runBenchmark(t, "1-provider-streaming",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 1}},
			NumUsers:      1,
			QueueCapacity: 100,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 30,
			Concurrency:   5,
			MaxTokens:     64,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_SingleProviderNonStreaming(t *testing.T) {
	runBenchmark(t, "1-provider-non-streaming",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 1}},
			NumUsers:      1,
			QueueCapacity: 100,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     false,
			TotalRequests: 20,
			Concurrency:   5,
			MaxTokens:     64,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_MultiModelMultiProvider(t *testing.T) {
	runBenchmark(t, "3-provider-multi-model",
		testbed.SuiteConfig{
			// Both models must be CBv2-servable (v0.7.5 one-engine) — a
			// non-CBv2 checkpoint never registers, so its share of the
			// round-robin would only measure routing failures. Keep this at
			// 2+1: all provider processes share one 48 GB virtual Apple runner,
			// so the former 4+3 topology could not construct every 12–14.5 GB
			// slot and measured host overcommit rather than network fan-out.
			ModelSpecs: []testbed.ModelSpec{
				{ModelID: testbed.DefaultTestModelID(), NumProviders: 2},
				{ModelID: testbed.SecondaryTestModelID(), NumProviders: 1},
			},
			NumUsers:      5,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 50,
			Concurrency:   10,
			MaxTokens:     64,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_HighConcurrency(t *testing.T) {
	runBenchmark(t, "3-provider-high-concurrency",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 3}},
			NumUsers:      10,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 60,
			Concurrency:   20,
			MaxTokens:     32,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_ProviderCapacityPressure(t *testing.T) {
	runBenchmark(t, "1-provider-capacity-pressure",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 1}},
			NumUsers:      10,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 40,
			Concurrency:   15,
			MaxTokens:     32,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_ManyUsers(t *testing.T) {
	runBenchmark(t, "3-provider-20-users",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 3}},
			NumUsers:      20,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   500_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 60,
			Concurrency:   10,
			MaxTokens:     32,
			Temperature:   0.0,
		},
	)
}

func TestBenchmark_SingleModelScaling(t *testing.T) {
	for _, numProviders := range []int{1, 3, 5} {
		t.Run(fmt.Sprintf("%d-providers", numProviders), func(t *testing.T) {
			runBenchmark(t, fmt.Sprintf("%d-provider-scaling", numProviders),
				testbed.SuiteConfig{
					ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: numProviders}},
					NumUsers:      5,
					QueueCapacity: 200,
					QueueTimeout:  120 * time.Second,
					SeedBalance:   500_000_000,
				},
				testbed.RequestConfig{
					Streaming:     true,
					TotalRequests: 30,
					Concurrency:   10,
					MaxTokens:     32,
					Temperature:   0.0,
				},
			)
		})
	}
}

func TestBenchmark_HeavyLoad_100Concurrent_10KB(t *testing.T) {
	runBenchmark(t, "3-provider-heavy-100conc-10kb",
		testbed.SuiteConfig{
			ModelSpecs:    []testbed.ModelSpec{{ModelID: testbed.DefaultTestModelID(), NumProviders: 3}},
			NumUsers:      20,
			QueueCapacity: 200,
			QueueTimeout:  120 * time.Second,
			SeedBalance:   2_000_000_000,
		},
		testbed.RequestConfig{
			Streaming:     true,
			TotalRequests: 100,
			Concurrency:   100,
			MaxTokens:     32,
			Temperature:   0.0,
			PromptBytes:   10 * 1024,
		},
	)
}

func minimumBenchmarkSuccesses(requests int) int {
	return (requests*benchmarkMinimumSuccessPercent + 99) / 100
}

func requireSuccessRatio(t *testing.T, cohort string, successes, requests int) {
	t.Helper()
	require.Positivef(t, requests, "%s received no requests", cohort)
	require.GreaterOrEqualf(t, successes*100, requests*benchmarkMinimumSuccessPercent,
		"%s success ratio %.1f%% is below %d%% (%d/%d)",
		cohort, float64(successes)*100/float64(requests),
		benchmarkMinimumSuccessPercent, successes, requests)
}
